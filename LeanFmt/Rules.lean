/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.ArtifactModel

import Lean

namespace LeanFmt.Internal

/-! # The rule engine

A rule declares what it needs to decide, and gets that and nothing more. The declaration is
`RuleImpl`'s constructor rather than a field, because the field drifted: `RuleInfo.input` was a
claim no code had to honor, and `RulePlan.requiresSyntax` answered `false` for the product's whole
life as a result. The shape is Lean's own
`Linter` (`Lean/Elab/Command.lean:64-70`) without the mutable ref that plugin loading needs and
this does not.

Rules run **outside** the compiler, against immutable facts. A rule cannot reach a workspace, a
cache, an `Environment`, or `IO`: `run` takes a fact view and returns an `Array Finding`. -/

/-- What a rule needs to decide, ordered by what it costs to obtain.

`source` facts are free: the file was read. `syntax` facts need the exact frontend, so a
run that selects any `syntax` rule needs a current `.olean` and its facet, or a frontend
invocation. `semantic` facts add the exact frontend's normalized compiler diagnostics, captured
only under rule demand, and the deprecation-occurrence facts a `.semantic` fix may read.

The `semantic` case has a producer, a consumer, and a test, so it is not the empty tier
`RuleInfo.input` rotted into. The producer is `analyzeExact` (`Analysis.lean`), gated by
`captureSemantic`. Formatting itself does not demand this tier — canonical layout is derived from the
syntax projection and validated independently — so a run pays for diagnostics only when a selected
rule reads them. -/
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

/-- What a `source`-tier rule may read: the module's normalized source, and the margin the file
is laid out to.

Normalized, never raw. `Parser.mkInputContext` normalizes before assigning any position, so
every compiler-produced offset indexes `raw.crlfToLf`; a finding measured against the file's own
bytes and a projection measured against the normalized string are two coordinate systems in one
artifact. Only reading a file and publishing one may touch raw bytes.

`bytes` is derived once. Source rules work on bytes, and computing `normalized.toUTF8` inside each
rule would walk the source once per rule. Sharing that derivation is why this is a structure rather
than a bare `String`.

`lineWidth` is `format.line-width` for *this* file — configuration, and the one kind a rule may
read. The line the reader sees is the file's bytes measured against the project's margin, so a rule
about it needs both; there is no width-free statement of the question. Two conditions make it safe,
and a third kind of configuration fails both, which is why the exemption does not generalize:

- It is already in cache identity. `Project.configurationIdentity` folds `format.identityString`,
  which spells `line-width=`, into `CacheIdentity.configuration`, so a width change misses every
  stored entry rather than serving findings computed at the old margin.
- It cannot decide whether a rule runs. `runRules` still produces every rule's findings and
  `RulePlan.findings` still projects afterwards, so one entry serves any `--select`.

`[lint]`'s selection and `extend-safe-fixes` fail both: they are not in the format identity, and
they are exactly the "rule reads its own enablement" mechanism that once made `check` and `format`
report different findings for the same unchanged file. See `docs/adding-a-rule.md`. -/
structure SourceFacts where private mk ::
  normalized : String
  bytes : ByteArray
  lineWidth : Nat

/-- `normalized` must be `(LosslessSource.normalize raw).1`, and `lineWidth` the effective
`format.line-width` for the file it came from. -/
def SourceFacts.of (normalized : String) (lineWidth : Nat) : SourceFacts :=
  { normalized, bytes := normalized.toUTF8, lineWidth }

/-- What a `syntax`-tier rule may read: the exact frontend's lossless projection, and the
source it indexes. A syntax rule needs both — `LosslessSource` is offsets into the normalized
string — so this nests `SourceFacts` rather than restating it. -/
structure SyntaxFacts where private mk ::
  source : SourceFacts
  projection : LosslessSource

/-- `normalized` must be the string `projection` indexes, which `LosslessSource.validFor`
proves. This does not re-check it: every caller passes a `validFor` first, and re-deriving the
projection's own validity inside the fact view would make the check circular rather than
independent. -/
def SyntaxFacts.of (normalized : String) (projection : LosslessSource) (lineWidth : Nat) :
    SyntaxFacts :=
  { source := SourceFacts.of normalized lineWidth, projection }

/-- What a `semantic`-tier rule may read: the syntax projection plus the exact frontend's
normalized compiler diagnostics. A semantic rule needs the syntax facts too — its range coordinate
system and suppression are the projection's — so this nests `SyntaxFacts` as `SyntaxFacts` nests
`SourceFacts`. `diagnostics` are the immutable facts (`ArtifactModel.Diagnostic`) the surfaced
rules FMT012–FMT015 key on; a rule never sees an `Environment`, a `Position`, or a `FileMap`, only
this data. -/
structure SemanticFacts where private mk ::
  «syntax» : SyntaxFacts
  diagnostics : Array Diagnostic
  /-- The owned deprecation-occurrence facts, empty unless the run demanded
  the `occurrences` capability. A rule reads this as plain data; an empty array is *no fixes to
  offer* (whether because nothing was captured or nothing was found — the two are distinguished at
  the cache layer, not here), so a rule stays report-only on empty and the `check` path never
  triggers the walk. -/
  occurrences : Array DeprecatedOccurrence

/-- `normalized` must be the string `projection` indexes, the same contract `SyntaxFacts.of`
carries. `diagnostics` are the projection's captured `Diagnostic`s, already in normalized-source
coordinates; `occurrences` are the owned deprecation-occurrence facts (empty when the capability
was not demanded). -/
def SemanticFacts.of (normalized : String) (projection : LosslessSource) (lineWidth : Nat)
    (diagnostics : Array Diagnostic) (occurrences : Array DeprecatedOccurrence := #[]) :
    SemanticFacts :=
  { «syntax» := SyntaxFacts.of normalized projection lineWidth, diagnostics, occurrences }

/-- The facts a run actually obtained. `SyntaxFacts` contains `SourceFacts` and
`SemanticFacts` contains `SyntaxFacts`, so richer facts run every cheaper rule too, and one run
never needs two fact objects. -/
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

The constructor *is* the tier declaration. A rule cannot claim one tier and read another,
because the tier decides the argument type — the difference between this and the `input` field it
replaces. -/
inductive RuleImpl where
  | source (run : SourceFacts → Array Finding)
  | «syntax» (run : SyntaxFacts → Array Finding)
  | semantic (run : SemanticFacts → Array Finding)

def RuleImpl.tier : RuleImpl → Tier
  | .source _ => .source
  | .syntax _ => .syntax
  | .semantic _ => .semantic

/-- A rule's **stability promise**, orthogonal
to `defaultEnabled`:

- `stable` — the rule's meaning is frozen; a change of meaning requires a *new* code. Selectable by
  `all`/`default`/category/code without a gate.
- `preview` — experimental; meaning or behavior may change without a new code. Reachable only under
  preview mode (`--preview`/`preview = true`), never by `all`/`default`/category otherwise, and
  never default-enabled.
- `deprecated` — superseded (by another rule, or by canonical formatting); still resolves for
  back-compat, carries a `replacement?`, and is never default-enabled.

`retired` is deliberately absent: a retired code has no `RuleImpl` and no `RuleInfo`, so it lives
in `reservedCodes`, not here. The three constructors plus the reserved table partition every
non-meta code. -/
inductive Lifecycle where
  | stable
  | preview
  | deprecated
  deriving Inhabited, BEq, DecidableEq, Repr

def Lifecycle.toWire : Lifecycle → String
  | .stable => "stable"
  | .preview => "preview"
  | .deprecated => "deprecated"

instance : Lean.ToJson Lifecycle :=
  ⟨fun l => .str l.toWire⟩

instance : Lean.FromJson Lifecycle :=
  ⟨fun j => do
    match ← j.getStr? with
    | "stable" =>
      pure .stable
    | "preview" =>
      pure .preview
    | "deprecated" =>
      pure .deprecated
    | other =>
      .error s!"unknown lifecycle: {other}"⟩

/-- One **executable** documentation example for a rule. `bad` is source the rule must flag; `good?` is the post-fix source for a fixable rule
and `none` for a report-only one. The catalog-invariant test runs each `bad` through the rule
(source-tier in process; syntax/semantic through the real-frontend harnesses) and, for a fixable
rule, asserts the emitted fix turns `bad` into `good?`. So an example that does not fire, or a fix
that does not produce the stated `good`, fails the build — the "invalid examples" detection. -/
structure RuleExample where
  bad : String
  good? : Option String := none
  deriving BEq, Repr

/-- What a rule tells a user about itself. Its tier is not in here: `Rule.tier` derives it
from the implementation, so the two cannot disagree. -/
structure RuleInfo where
  code : String
  category : String
  summary : String
  fixable : Bool
  defaultEnabled : Bool
  /-- The stability promise (`Lifecycle`). Orthogonal to `defaultEnabled`: a `stable` rule
  may be default-on or default-off, but a `preview`/`deprecated` rule is never default-on (a test
  pins this). -/
  lifecycle : Lifecycle
  /-- Long-form explanation shown by `explain` and the generated rule page. One or more
  paragraphs; must be nonempty for a live rule. -/
  explanation : String
  /-- Executable bad→good examples (≥1 for a live rule). -/
  examples : Array RuleExample
  /-- The successor code for a `deprecated` rule (its migration path); `none` otherwise.
  Required to be `some` iff `lifecycle == .deprecated`. -/
  replacement? : Option String := none
  /-- What would graduate this rule out of preview. Required to be `some` and nonempty **iff**
  `lifecycle == .preview`, and surfaced by `explain` and the generated page, because a preview rule whose path out
  lives only in a result note is a rule nobody will revisit.

  It states a *checkable* condition, not a sentiment: "graduates when it produces ≥10 audited true
  positives with zero false positives on a corpus that …" and not "needs more evidence". The
  current ten are derived from measured corpus behaviour — eight of these
  rules never fired on 85 real mathlib modules, so what each one names is the corpus that would
  actually exercise it.

  The invariant is what keeps this honest. An unenforced field rots exactly as a declared tier
  field would (`CLAUDE.md`), so `testCatalogInvariants` pins it in both directions. -/
  previewPath? : Option String := none
  /-- Whether this rule's fix reads the owned deprecation-occurrence fact. It
  governs *capture cost only*: `RulePlan.demandedCaps` sets the `occurrences` capability — and pays
  the whole-file info-tree fold — when and only when a selected rule declares this in a rendering
  mode. A wrong value never corrupts a file, since the output re-elaboration validator still checks
  the fix; it only over- or under-captures. Unlike a tier field, the tier system does not enforce
  it, so a test pins that a `needsOccurrences` rule is `.semantic` and that its fix appears iff
  occurrences were captured. -/
  needsOccurrences : Bool := false
  deriving BEq

structure Rule where
  info : RuleInfo
  impl : RuleImpl

def Rule.code (rule : Rule) : String :=
  rule.info.code

def Rule.tier (rule : Rule) : Tier :=
  rule.impl.tier

/-- The `lean-fmt rules` wire shape. `input` is derived from the implementation rather
than read from a field, so it cannot describe a rule that does something else. -/
instance : Lean.ToJson Rule where
  toJson rule :=
    Lean.Json.mkObj
      [("code", .str rule.info.code), ("category", .str rule.info.category),
        ("summary", .str rule.info.summary), ("fixable", .bool rule.info.fixable),
        ("defaultEnabled", .bool rule.info.defaultEnabled),
        ("lifecycle", Lean.toJson rule.info.lifecycle), ("input", Lean.toJson rule.tier)]

/-! ## Source-security rules

`FMT001` and `FMT002` flag bytes that survive into accepted source only inside a string
literal or a comment: a bare control byte or bidirectional mark in the command stream is a hard
parse error, so a file carrying one in code is not accepted source and no source rule runs on it.
The parser's acceptance therefore supplies the token context these
rules would otherwise need: they scan bytes, and every byte they can see already sits in a string
or comment. Both are **report-only**: deleting the byte would change string data or comment text,
which no byte-level argument can call safe. -/

private def hexDigit (n : Nat) : Char :=
  if n < 10 then Char.ofNat (n + '0'.toNat) else Char.ofNat (n - 10 + 'A'.toNat)

/-- Uppercase four-digit hex, for the `U+XXXX` in a message. Every code these rules name is
`≤ 0xFFFF`, so four digits is exact, not a truncation. -/
private def hex4 (n : Nat) : String :=
  String.ofList
    [hexDigit (n / 4096 % 16), hexDigit (n / 256 % 16), hexDigit (n / 16 % 16), hexDigit (n % 16)]

/-- The `FMT001` set: C0 controls except TAB (`0x09`) and LF (`0x0A`), plus DEL (`0x7F`). CR
(`0x0D`) is unreachable — it cannot survive into accepted normalized source — so its inclusion is
moot. TAB is excluded: it is legitimate string content and its bare form is a read-boundary
rejection, never a lint concern here. -/
private def isForbiddenControl (byte : UInt8) : Bool :=
  (byte < 0x20 && byte != 0x09 && byte != 0x0a) || byte == 0x7f

private def controlFinding (start : Nat) (codepoint : Nat) : Finding :=
  { code := "FMT001"
    severity := .warning
    message := s!"forbidden control byte U+{hex4 codepoint}"
    range := { start, stop := start + 1 }
    -- Report-only: the byte is inside a string literal or comment, so removing it changes
    -- program data or comment text — not a safe byte-level edit.
    fix? := none }

/-- A single byte scan; no UTF-8 decoding, because every forbidden byte is one ASCII byte
and can never be a continuation byte of a multibyte scalar. -/
private def forbiddenControlByte (facts : SourceFacts) : Array Finding :=
  Id.run do
    let bytes := facts.bytes
    let mut findings := #[]
    for index in [0:bytes.size] do
      let byte := bytes.get! index
      if isForbiddenControl byte then
        findings := findings.push (controlFinding index byte.toNat)
    return findings

/-- The `FMT002` set: the twelve Unicode bidirectional formatting controls of the
Trojan-Source attack (CVE-2021-42574). -/
private def isBidiControl (c : Char) : Bool :=
  let n := c.toNat
  n == 0x061c || (0x200e ≤ n && n ≤ 0x200f) || (0x202a ≤ n && n ≤ 0x202e) ||
    (0x2066 ≤ n && n ≤ 0x2069)

private def bidiFinding (start width codepoint : Nat) : Finding :=
  { code := "FMT002"
    severity := .warning
    message := s!"suspicious bidirectional control U+{hex4 codepoint}"
    range := { start, stop := start + width }
    -- Report-only for the same reason as `FMT001`: the mark is string data or comment text.
    fix? := none }

/-- One left fold over the normalized string, decoding each scalar once and carrying the
running byte offset in the accumulator, so the range is the mark's exact UTF-8 span without a
second pass. -/
private def bidiControl (facts : SourceFacts) : Array Finding :=
  let step := fun (state : Nat × Array Finding) (c : Char) =>
    let (bytePos, findings) := state
    let findings :=
      if isBidiControl c then findings.push (bidiFinding bytePos c.utf8Size c.toNat) else findings
    (bytePos + c.utf8Size, findings)
  (facts.normalized.foldl step (0, #[])).2

/-- The finding covers the overflow, not the whole row: the row's first `lineWidth` characters are
within the margin and highlighting them says nothing. The message carries the row's width because a
range in a report tells the reader where, not how far over. -/
private def overlongLineFinding (start stop width lineWidth : Nat) : Finding :=
  { code := "FMT016"
    severity := .warning
    message := s!"line is {width} characters wide, over the {lineWidth}-character line width"
    range := { start, stop }
    -- Report-only: where to break a line is a choice about what the code means, and `format`
    -- already made the one it could. A row still over the margin after formatting is one no
    -- break placement fixes.
    fix? := none }

/-- Rows are counted in **characters**, not bytes, because that is what `Std.Format` counts when
it decides where to break: a rule measuring bytes would report rows the layout engine considers
inside the margin, on every file that uses `∀` or `→`.

One pass, carrying the byte offset where the row crossed the margin, so the finding's range needs
no second walk. The final row is checked after the fold because normalized source need not end in a
newline. -/
private def overlongLine (facts : SourceFacts) : Array Finding :=
  Id.run do
    let limit := facts.lineWidth
    let mut findings := #[]
    let mut bytePos := 0
    let mut column := 0
    let mut overflowAt := 0
    for c in facts.normalized do
      if c == '\n' then
        if column > limit then
          findings := findings.push (overlongLineFinding overflowAt bytePos column limit)
        column := 0
      else
        if column == limit then
          overflowAt := bytePos
        column := column + 1
      bytePos := bytePos + c.utf8Size
    if column > limit then
      findings := findings.push (overlongLineFinding overflowAt bytePos column limit)
    return findings

/-! ## Syntax-tier rules

`FMT006`–`FMT011` read the exact frontend's projection through `SyntaxFacts`: node **kinds
as strings**, child/token adjacency, and leaf source text. None reads `Lean.Syntax`, precedence
(the projection carries none), or `choice` alternatives (only the first survives). Every kind
string is cited to the pinned v4.32.0 compiler and was read off real projections. A wrong kind
string is a rule that silently never fires, so these come from the census, not from memory. -/

private def kModuleDoc :=
  "Lean.Parser.Command.moduleDoc"

private def kDeclaration :=
  "Lean.Parser.Command.declaration"

private def kNamespace :=
  "Lean.Parser.Command.namespace"

private def kSection :=
  "Lean.Parser.Command.section"

private def kEnd :=
  "Lean.Parser.Command.end"

private def kAttributes :=
  "Lean.Parser.Term.attributes"

private def kAttrInstance :=
  "Lean.Parser.Term.attrInstance"

private def kDerivingClass :=
  "Lean.Parser.Command.derivingClass"

private def kSetOption :=
  "Lean.Parser.Command.set_option"

private def kParen :=
  "Lean.Parser.Term.paren"

private def kHygienicLParen :=
  "Lean.Parser.Term.hygienicLParen"

/-- Source text of a normalized byte range, decoded as UTF-8. Ranges index the normalized
source, so this is exact; an invalid slice (never produced by a validated projection) decodes to
`""`. -/
private def rangeText (bytes : ByteArray) (start stop : Nat) : String :=
  (String.fromUTF8? (bytes.extract start stop)).getD ""

/-! ### FMT006 — module lacks a module docstring

Fires when the module has at least one `declaration` command but no `moduleDoc` (`/-! … -/`)
node. A declaration-level `/-- … -/` is a `docComment` inside `declModifiers`, a different kind, so
it does not satisfy the rule. Report-only: the missing thing is documentation text, which no
formatter can write. The finding is a caret at `headerStop` — where a module doc belongs, right
after the header. -/

private def moduleDocRequired (facts : SyntaxFacts) : Array Finding :=
  Id.run do
    let projection := facts.projection
    let mut firstDecl : Option Nat := none
    let mut hasModuleDoc := false
    for i in [0:projection.nodes.size] do
      -- A `moduleDoc` or `declaration` inside a `` `(…) `` quotation is quoted data, not
      -- this module's own docstring or declaration, so it neither satisfies nor triggers the
      -- requirement.
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
          code := "FMT006"
          severity := .warning
          message := "module has declarations but no module docstring"
          range := { start := insertion, stop := insertion }
          fix? := none }]

/-! ### FMT007 — unclosed `section` or `namespace`

Matching is a name stack over the top-level command stream, as
`Lean.Elab.Command`'s scope stack works. `namespace Foo` pushes the name `Foo`;
`section` pushes an anonymous scope; `section Bar` pushes `Bar`. A bare `end` pops one scope (the
innermost, an anonymous section in accepted source). An `end Foo` pops the scopes whose names,
concatenated outer→inner with `.`, spell `Foo` — so **one** `end A.B` closes both a single
`namespace A.B` (one scope named `A.B`) **and** a `namespace A` / `namespace B` pair (two scopes).
Popping only one per `end` is the false positive this rule shipped and RYR-FINAL's frozen-sample
review caught on `Mathlib/Probability/Kernel/Deterministic.lean` (`namespace ProbabilityTheory` /
`namespace Kernel` closed by one `end ProbabilityTheory.Kernel`). At the terminal, remaining opens
are reported, except an outermost anonymous `noncomputable`/`public`/`meta` section (the idiomatic
whole-file section), dropped to mirror Mathlib's `linter.style.missingEnd`. Report-only: where a
scope *should* have closed is author judgment. -/

private structure OpenScope where
  opener : Nat
  isSection : Bool
  named : Bool
  name : String
  outerSectionOk : Bool
  deriving Inhabited

/-- The whitespace-delimited words of a top-level scope command's node text. The node
range is the leaf hull (trivia excluded), so these words are the keyword, any modifiers, and the
scope name — e.g. `["noncomputable", "section", "Foo"]`, `["namespace", "A.B"]`, or
`["end", "A.B"]`. Splitting on whitespace rather than on the keyword substring avoids mis-parsing
a name that contains the keyword (e.g. a `Legendre` namespace). -/
private def scopeWords (text : String) : List String :=
  (text.splitOn " ").filter (·.length > 0)

private def unclosedScopes (facts : SyntaxFacts) : Array Finding :=
  Id.run do
    let projection := facts.projection
    let bytes := facts.source.bytes
    let mut stack : Array OpenScope := #[]
    -- Only the top-level command stream is walked, and a quotation node always has a parent, so
    -- a `namespace`/`section`/`end` quoted inside `` `(…) `` is never in this loop — no
    -- `inQuotation` guard is needed here, unlike the node-scanning rules below.
    for i in projection.topLevelNodes do
      let kind := projection.kindOf i
      let text :=
        rangeText bytes (projection.nodes[i]!.range.start) (projection.nodes[i]!.range.stop)
      if kind == kNamespace then
        -- `namespace <name>` — the name is the one word after the keyword. Fields, in
        -- order: opener, isSection, named, name, outerSectionOk.
        let scopeName := (scopeWords text).getD 1 ""
        stack := stack.push ⟨i, false, true, scopeName, false⟩
      else if kind == kSection then
        let words := scopeWords text
        let sectionIdx := words.findIdx (· == "section")
        -- The name is the word after `section` (absent for an anonymous section); modifiers
        -- precede it.
        let scopeName := words.getD (sectionIdx + 1) ""
        let outerOk :=
          (words.take sectionIdx).any fun word =>
            word == "noncomputable" || word == "public" || word == "meta"
        stack := stack.push ⟨i, true, scopeName.length > 0, scopeName, outerOk⟩
      else if kind == kEnd then
        let endName := (scopeWords text).getD 1 ""
        if endName.isEmpty then
          if !stack.isEmpty then
            stack := stack.pop
        else
          -- Pop scopes from the top, accumulating names, until the outer→inner join spells
          -- `endName`. Accepted source always matches; on no match (unexpected input) fall back to
          -- a single pop.
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
    while
      lower < stack.size &&
        (stack[lower]!.isSection && !stack[lower]!.named && stack[lower]!.outerSectionOk) do
      lower := lower + 1
    if lower >= stack.size then
      return #[]
    let scope := stack[lower]!
    let range := projection.nodes[scope.opener]!.range
    let what := if scope.isSection then "section" else "namespace"
    return #[{
          code := "FMT007"
          severity := .warning
          message := s!"unclosed {what}"
          range
          fix? := none }]

/-- Duplicate detection shared by FMT008/FMT009: among sibling nodes of one `owner` kind,
an entry whose byte-identical text already appeared earlier in the same list is a duplicate. The
fix deletes the duplicate together with its preceding `", "` separator — `[previous sibling stop,
duplicate stop)` — so `@[simp, simp]` becomes `@[simp]` and `deriving Repr, Repr` becomes
`deriving Repr`. Safe: an exact repeat is idempotent, so removing it preserves what the elaborator
records. -/
private def duplicateSiblings (bytes : ByteArray) (projection : LosslessSource)
    (childAdjacency : Array (Array Nat)) (memberKind code message : String) (nodeIndex : Nat) :
    Array Finding :=
  Id.run do
    let members := (childAdjacency[nodeIndex]!).filter fun j => projection.kindOf j == memberKind
    let mut texts : Array String := #[]
    let mut findings := #[]
    for idx in [0:members.size] do
      let range := projection.nodes[members[idx]!]!.range
      -- The node range is the leaf hull, so leading/trailing trivia is already excluded;
      -- the text is the instance's own bytes, and two exact duplicates compare equal here.
      let text := rangeText bytes range.start range.stop
      if texts.contains text then
        let prevStop := projection.nodes[members[idx - 1]!]!.range.stop
        let editRange : SourceRange := { start := prevStop, stop := range.stop }
        findings :=
          findings.push
            { code
              severity := .warning
              message
              range
              fix? :=
                some
                  { applicability := .safe,
                    edits := #[{ range := editRange, replacement := "" }] } }
      texts := texts.push text
    return findings

/-! ### FMT008 — duplicate attribute in one `@[…]` list. ### FMT009 — duplicate `deriving`
class. Both are `duplicateSiblings` over the relevant owner/member kinds. -/

private def duplicateAttribute (facts : SyntaxFacts) : Array Finding :=
  Id.run do
    let projection := facts.projection
    let bytes := facts.source.bytes
    let childAdjacency := projection.childAdjacency
    let mut findings := #[]
    -- `attributes` is `"@[" >> sepBy1 attrInstance ", " >> "]"`, and `sepBy1` inserts a null
    -- group node, so the `attrInstance`s are children of that group, not of `attributes` directly.
    -- Grouping by the actual parent (any node with `attrInstance` children) survives that
    -- intermediate, as FMT009 does for `derivingClass`.
    for i in [0:projection.nodes.size] do
      if projection.inQuotation i then
        continue
      if (childAdjacency[i]!).any fun j => projection.kindOf j == kAttrInstance then
        findings :=
          findings ++
            duplicateSiblings bytes projection childAdjacency kAttrInstance "FMT008"
              "duplicate attribute in attribute list" i
    return findings

private def duplicateDerivingClass (facts : SyntaxFacts) : Array Finding :=
  Id.run do
    let projection := facts.projection
    let bytes := facts.source.bytes
    let childAdjacency := projection.childAdjacency
    let mut findings := #[]
    -- `derivingClass` nodes sit under the `sepBy1` group node; grouping by that parent makes
    -- them siblings, whichever intermediate the parser inserted. Any node with `derivingClass`
    -- children is an owner, so scan every node once.
    for i in [0:projection.nodes.size] do
      if projection.inQuotation i then
        continue
      if (childAdjacency[i]!).any fun j => projection.kindOf j == kDerivingClass then
        findings :=
          findings ++
            duplicateSiblings bytes projection childAdjacency kDerivingClass "FMT009"
              "duplicate deriving class" i
    return findings

/-! ### FMT010 — development-only `set_option`

Fires on a `set_option` command whose option name root is `debug`, `pp`, `profiler`, or
`trace` — the exact set of Mathlib's `linter.style.setOption`. Matching the `set_option` **node**
(not the string) means a `set_option`-looking string literal or comment never fires. Report-only:
removing a committed option is author intent, and for the `… in` forms the scoped boundary is not
a byte-safe question. -/

private def isDevelopmentOption (name : String) : Bool :=
  let root := (name.splitOn ".").headD name
  root == "debug" || root == "pp" || root == "profiler" || root == "trace"

private def developmentSetOption (facts : SyntaxFacts) : Array Finding :=
  Id.run do
    let projection := facts.projection
    let bytes := facts.source.bytes
    let tokensByNode := projection.tokensByNode
    let mut findings := #[]
    for i in [0:projection.nodes.size] do
      if projection.inQuotation i then
        continue
      if projection.kindOf i == kSetOption then
        let tokens := tokensByNode[i]!
        -- tokens[0] is the `set_option` keyword atom; tokens[1] is the option-name
        -- identifier.
        if tokens.size ≥ 2 then
          let nameToken := tokens[1]!
          let name := rangeText bytes nameToken.start nameToken.stop
          if isDevelopmentOption name then
            findings :=
              findings.push
                { code := "FMT010"
                  severity := .warning
                  message := s!"development-only option '{name}' set in committed source"
                  range := { start := projection.nodes[i]!.range.start, stop := nameToken.stop }
                  fix? := none }
    return findings

/-! ### FMT011 — redundant nested parentheses

Fires on a `paren` node whose only child **node** is itself a `paren` — `((e))`. The inner
`(e)` is a complete atomic term, so dropping the outer pair cannot regroup anything; no precedence
is consulted (the projection has none), which is why only the nested case is answerable here. The
fix deletes the outer `(` and `)` as two edits. Preview default until RYR-FINAL measures its
tree-shape rate. -/

private def redundantNestedParen (facts : SyntaxFacts) : Array Finding :=
  Id.run do
    let projection := facts.projection
    let childAdjacency := projection.childAdjacency
    let mut findings := #[]
    for i in [0:projection.nodes.size] do
      if projection.inQuotation i then
        continue
      if projection.kindOf i == kParen then
        -- A `paren` node is `hygienicLParen >> term >> ")"`; the `(` is itself a
        -- `hygienicLParen` node, so a paren has two child nodes and the *term* is the one that is
        -- not the opener. The rule fires when that term is itself a `paren` — `((e))`.
        let inner := (childAdjacency[i]!).filter fun j => projection.kindOf j != kHygienicLParen
        if inner.size == 1 && projection.kindOf inner[0]! == kParen then
          let outer := projection.nodes[i]!.range
          let inner := projection.nodes[inner[0]!]!.range
          findings :=
            findings.push
              { code := "FMT011"
                severity := .warning
                message := "redundant nested parentheses"
                range := outer
                fix? :=
                  some
                    { applicability := .safe,
                      edits :=
                        #[{ range := { start := outer.start, stop := inner.start },
                            replacement := "" },
                          { range := { start := inner.stop, stop := outer.stop },
                            replacement := "" }] } }
    return findings

/-! ## Semantic-tier rules

`FMT012`–`FMT015` **surface** compiler diagnostics the exact frontend already emitted, keyed on
each message's stable top-level `kind` tag (a linter option name, or the deprecation attribute).
They read `SemanticFacts.diagnostics` — normalized `Diagnostic`s already in the projection's
coordinate system, captured from the `MessageLog` in `Analysis.lean` — and conclude a report-only
`Finding` that preserves the compiler's own message as detail. They re-derive nothing:
reconstructing an unused-variable diagnostic would mean reimplementing a linter from info trees and
the metavariable context — a brittle invention.

Every rule is **report-only**: removing a binder or a section variable, or renaming a deprecated
reference, is not an edit any byte-level or projection fact here can prove safe. The four `kind`
strings were read first-hand off the v4.32.0 compiler; a wrong string is a rule that silently never fires. A
toolchain that stops emitting one of these kinds yields no findings, because surfacing only ever
reads a tag the running compiler produced. -/

private def kDeprecatedAttr :=
  "Lean.Linter.deprecatedAttr"

private def kUnusedVariables :=
  "linter.unusedVariables"

private def kUnusedSectionVars :=
  "linter.unusedSectionVars"

private def kConstructorNameAsVariable :=
  "linter.constructorNameAsVariable"

/-- The compiler-message `kind` tags the semantic rules surface, and the list the capture
(`Analysis.lean`) filters by. Capture and rules read one array, so a captured diagnostic always has
a rule and a rule never keys on a tag the capture drops — the discipline `runRulesOf` and
`requiredTierOf` share one registry for. -/
def surfacedDiagnosticKinds : Array String :=
  #[kDeprecatedAttr, kUnusedVariables, kUnusedSectionVars, kConstructorNameAsVariable]

/-- Surface every captured diagnostic of one `kind` as a report-only finding under
`code`, preserving the compiler's original `message`, `severity`, and `range`. No fix: see the
section note. -/
private def surfaceDiagnostics (kind code : String) (facts : SemanticFacts) : Array Finding :=
  facts.diagnostics.filterMap fun d =>
    if d.kind == kind then
      some { code, severity := d.severity, message := d.message, range := d.range, fix? := none }
    else none

/-- FMT012 — use of a deprecated declaration (`@[deprecated]`), tag `Lean.Linter.deprecatedAttr`.

The **report** is surfaced from the compiler diagnostic — unchanged, always available,
cheap. The **unsafe rename fix** is attached from the owned occurrence fact only when it was
captured: for each surfaced finding, a *fixable* occurrence at the same range
contributes a `Fix` that replaces the identifier with the deprecation's `newName?`. When
occurrences were not captured — `check`, or any run that did not demand the `occurrences`
capability — `facts.occurrences` is empty and every finding is report-only, byte-identical to the
surfaced-only behavior. The fix is `unsafe`: a textual name swap is plausibly intended but
unproven, applied only under `--unsafe-fixes` and backstopped by the output re-elaboration
validator. -/
private def deprecatedUse (facts : SemanticFacts) : Array Finding :=
  (surfaceDiagnostics kDeprecatedAttr "FMT012" facts).map fun finding =>
    match facts.occurrences.find? (fun o => o.fixable && o.range == finding.range) with
    | some occ =>
      match occ.newName? with
      | some replacement =>
        { finding with
          fix? :=
            some { applicability := .unsafe, edits := #[{ range := occ.range, replacement }] } }
      | none => finding
    | none => finding

/-- FMT013 — unused variable / binder, tag `linter.unusedVariables`. -/
private def unusedVariable (facts : SemanticFacts) : Array Finding :=
  surfaceDiagnostics kUnusedVariables "FMT013" facts

/-- FMT014 — automatically-included section variable unused in a theorem, tag
`linter.unusedSectionVars`. -/
private def unusedSectionVariable (facts : SemanticFacts) : Array Finding :=
  surfaceDiagnostics kUnusedSectionVars "FMT014" facts

/-- FMT015 — bound variable resembles a nullary constructor, tag `linter.constructorNameAsVariable`. -/
private def constructorNameVariable (facts : SemanticFacts) : Array Finding :=
  surfaceDiagnostics kConstructorNameAsVariable "FMT015" facts

/-- Every rule the product ships, in one static array.

Static, not an attribute or an environment extension. The rule set is compiled and first-party,
so a dynamic table would buy nothing and cost determinism: `lean-fmt rules` output and pre-sort
finding order would depend on import order. Lean stores its own linters in a mutable ref for one
stated reason — "Linters should be loadable as plugins" (`Lean/Elab/Command.lean:108-109`) — and
this product has no public runtime plugin interface.

Accepted source cannot contain an isolated `\r`, so after normalization no carriage return
survives for a line-oriented rule to consider. -/
def ruleRegistry : Array Rule :=
  #[{ info :=
        { code := "FMT001"
          category := "security"
          summary := "reject forbidden control bytes in source"
          fixable := false
          defaultEnabled := true
          lifecycle := .stable
          explanation :=
            "\
A C0 control byte other than TAB or LF, or the DEL byte (U+007F), appears in the source. In accepted \
Lean these bytes can only survive inside a string literal or a comment — a bare control byte in the \
command stream is a parse error — so the finding always lands on program data or human-read text. It is \
report-only: deleting the byte would change that data or text, which no byte-level argument can call \
safe. Illustrative (the byte cannot be shown verbatim): a string \"a<U+0000>b\" carrying an embedded \
NUL is flagged at the NUL."
          -- Example-exempt (see `exampleExemptCodes`): a verbatim control byte cannot be
          -- embedded in documentation or printed by `explain`, so the explanation carries an escaped
          -- illustration.
          examples := #[] }
      impl := .source forbiddenControlByte },
    { info :=
        { code := "FMT002"
          category := "security"
          summary := "flag suspicious bidirectional controls in source"
          fixable := false
          defaultEnabled := true
          lifecycle := .stable
          explanation :=
            "\
One of the twelve Unicode bidirectional formatting controls of the Trojan-Source attack \
(CVE-2021-42574) appears in the source — inside a string or comment, since a bare one does not parse. \
These marks can reorder how a line renders without changing its bytes, so committed code can read \
differently from what the compiler sees. Report-only: the mark is string data or comment text, so \
removing it is not a byte-safe edit. Illustrative (the mark cannot be shown verbatim): a comment \
ending in a right-to-left override U+202E is flagged at the mark."
          -- Example-exempt (see `exampleExemptCodes`): a verbatim bidi mark would reorder the doc itself.
          examples := #[] }
      impl := .source bidiControl },
    { info :=
        { code := "FMT006"
          category := "docs"
          summary := "require a module docstring when a module declares anything"
          fixable := false
          defaultEnabled := false
          lifecycle := .preview
          explanation :=
            "\
A module contains at least one declaration but no module docstring (`/-! … -/`). A declaration-level \
`/-- … -/` is a different node and does not satisfy the requirement. Report-only: the missing thing is \
documentation prose, which no formatter can write; the finding is a caret where a module doc belongs, \
just after the header."
          previewPath? :=
            "\
Graduates when it produces at least 10 audited true positives with zero false positives on a corpus of \
Lean projects that do not already enforce module docstrings in CI. The tree-compliance half is met as \
of 2026-07-28: every module of the product and every test module carries a module docstring, and the 21 \
files this rule still reports are formatter fixtures, whose layout is the thing under test — prose in \
one would change what it tests."
          examples := #[{ bad := "def answer : Nat := 42\n" }] }
      impl := .syntax moduleDocRequired },
    { info :=
        { code := "FMT007"
          category := "structure"
          summary := "report an unclosed section or namespace"
          fixable := false
          defaultEnabled := false
          lifecycle := .preview
          explanation :=
            "\
A `section` or `namespace` is opened and never closed by a matching `end`, tracked as a scope-name \
stack over the top-level command stream (one `end A.B` closes both a single `namespace A.B` and an \
`A`/`B` pair). An outermost anonymous `noncomputable`/`public`/`meta` section — the idiomatic whole-file \
section — is not reported. Report-only: where a scope *should* close is author judgment."
          previewPath? :=
            "\
Graduates when the whole-file NAMED namespace case is settled, and then only with at least 10 audited \
true positives and zero false positives. The open question is this rule's own contract: it already \
declines to report the idiomatic whole-file *anonymous* section, and a named namespace spanning an \
entire file is arguably the same idiom. Its one corpus finding \
(mathlib `scripts/create_deprecated_modules.lean:21`) is exactly that case. Settle it by carving the \
case out or by keeping it reportable with the reason recorded; until then the meaning is not ready to \
freeze, which is what `stable` would promise."
          examples := #[{ bad := "namespace Demo\n\ndef answer : Nat := 42\n" }] }
      impl := .syntax unclosedScopes },
    { info :=
        { code := "FMT008"
          category := "redundancy"
          summary := "remove a duplicate attribute in an attribute list"
          fixable := true
          defaultEnabled := false
          lifecycle := .preview
          explanation :=
            "\
An `@[…]` attribute list names the same attribute twice. The safe fix deletes the later instance and \
its preceding separator, so `@[simp, simp]` becomes `@[simp]`. Safe: an exact repeat is idempotent, so \
removing it preserves what the elaborator records."
          previewPath? :=
            "\
Graduates when it produces at least 10 audited true positives with zero false positives on a corpus \
that is not attribute-reviewed — generated code, student code, or a project with no attribute linter. \
Its fix already passes the safety, idempotence, convergence, and composition audit; what is missing is \
evidence that the rule fires correctly on code its author did not write. It found nothing across 85 \
mathlib modules including `Mathlib/Data/Finset/Attr.lean`, which was chosen for being attribute-dense."
          examples :=
            #[{ bad := "@[simp, simp] def idem : Nat := 0\n"
                good? := "@[simp] def idem : Nat := 0\n" }] }
      impl := .syntax duplicateAttribute },
    { info :=
        { code := "FMT009"
          category := "redundancy"
          summary := "remove a duplicate deriving class"
          fixable := true
          defaultEnabled := false
          lifecycle := .preview
          explanation :=
            "\
A `deriving` clause names the same class twice. The safe fix deletes the later instance and its \
separator, so `deriving Repr, Repr` becomes `deriving Repr`. Safe for the same idempotence reason as \
FMT008."
          previewPath? :=
            "\
Graduates on the same condition as FMT008, for duplicate `deriving` classes: at least 10 audited true \
positives with zero false positives on a corpus that is not attribute-reviewed. Its fix passes the same \
audit; it found nothing across 85 mathlib modules."
          examples :=
            #[{ bad := "inductive Color where\n  | red\n  deriving Repr, Repr\n"
                good? := "inductive Color where\n  | red\n  deriving Repr\n" }] }
      impl := .syntax duplicateDerivingClass },
    { info :=
        { code := "FMT010"
          category := "debug"
          summary := "report a development-only set_option left in source"
          fixable := false
          defaultEnabled := false
          lifecycle := .preview
          explanation :=
            "\
A committed `set_option` sets an option whose root is `debug`, `pp`, `profiler`, or `trace` — the set \
Mathlib's `linter.style.setOption` flags. Matching the `set_option` node (not a string) means a \
`set_option`-looking string or comment never fires. Report-only: removing a committed option is author \
intent, and the scoped `… in` boundary is not a byte-safe question."
          previewPath? :=
            "\
Graduates when it produces at least 10 audited true positives with zero false positives on a corpus \
with no `set_option` linter of its own. mathlib cannot supply that evidence by construction: \
`linter.style.setOption` is this rule's near-exact equivalent, so the zero it scored across 85 mathlib \
modules says what mathlib already enforces and nothing about whether this rule is correct."
          examples := #[{ bad := "set_option trace.Meta.debug true\n\ndef answer : Nat := 42\n" }] }
      impl := .syntax developmentSetOption },
    { info :=
        { code := "FMT011"
          category := "redundancy"
          summary := "remove redundant nested parentheses"
          fixable := true
          -- `stable` but default-OFF. Its meaning is frozen and it is selectable by `all`, by
          -- `redundancy`, and by code with no `--preview` gate; it is absent from `default` because it
          -- is syntax tier, and a default syntax-tier rule measured at 33x the cold-path budget on an
          -- ordinary-built project (62 frontend children against the baseline's 1). Correctness earned
          -- the promotion; cost kept it off the default path. These are separate axes and `Lifecycle`
          -- is orthogonal to `defaultEnabled` exactly so this state can be expressed.
          defaultEnabled := false
          lifecycle := .stable
          explanation :=
            "\
A parenthesized term's only child is itself parenthesized — `((e))`. The inner `(e)` is already a \
complete atomic term, so dropping the outer pair cannot regroup anything; only the directly-nested case \
is answered, because the projection carries no precedence. The safe fix deletes the outer pair.\n\n\
This rule is stable but off by default. It is syntax tier, so running it on a project not built with \
the lean-fmt compiler plugin costs one compiler frontend run per module; select it with \
`--select FMT011`, or `--select redundancy`, or enable it in `lean-fmt.toml`."
          examples :=
            #[{ bad := "def twice : Nat := ((1))\n"
                good? := "def twice : Nat := (1)\n" }] }
      impl := .syntax redundantNestedParen },
    { info :=
        { code := "FMT012"
          category := "deprecation"
          summary := "report use of a deprecated declaration"
          fixable := true
          defaultEnabled := false
          lifecycle := .preview
          needsOccurrences := true
          explanation :=
            "\
A reference resolves to a declaration marked `@[deprecated]`; the report surfaces the compiler's own \
`Lean.Linter.deprecatedAttr` diagnostic unchanged. When the deprecation names a replacement and the run \
applies fixes, an **unsafe** rename fix is offered (a textual name swap is plausibly intended but \
unproven, so it applies only under `--unsafe-fixes` and is backstopped by output re-elaboration)."
          previewPath? :=
            "\
Graduates report-only when it produces at least 10 audited true positives with zero false positives on \
a corpus that actually uses deprecated declarations; it found none across 85 mathlib modules. The \
rename fix stays `unsafe` and opt-in regardless of that outcome, because a textual name swap is \
plausibly intended but unproven — so graduation would enable the report, never the fix."
          examples :=
            #[{ bad :=
                  "def new : Nat := 0\n@[deprecated new (since := \"1.0\")] def old : Nat := 0\ndef use : Nat := old\n"
                good? :=
                  "def new : Nat := 0\n@[deprecated new (since := \"1.0\")] def old : Nat := 0\ndef use : Nat := new\n" }] }
      impl := .semantic deprecatedUse },
    { info :=
        { code := "FMT013"
          category := "unused"
          summary := "report an unused variable or binder"
          fixable := false
          defaultEnabled := false
          lifecycle := .preview
          explanation :=
            "\
A bound variable or binder is never used, surfaced from the compiler's `linter.unusedVariables` \
diagnostic. Report-only: removing or renaming a binder is not an edit any byte-level or projection fact \
here can prove safe."
          previewPath? :=
            "\
Graduates when it produces at least 10 audited true positives with zero false positives on a corpus \
that is not already `linter.unusedVariables`-clean. mathlib runs that linter, so it cannot supply the \
evidence: the zero this rule scored across 85 mathlib modules measures mathlib's CI, not this rule."
          examples := #[{ bad := "def constZero (x : Nat) : Nat := 0\n" }] }
      impl := .semantic unusedVariable },
    { info :=
        { code := "FMT014"
          category := "unused"
          summary := "report a section variable unused in a theorem"
          fixable := false
          defaultEnabled := false
          lifecycle := .preview
          explanation :=
            "\
An automatically-included section `variable` is unused in a theorem, surfaced from the compiler's \
`linter.unusedSectionVars` diagnostic. Report-only, for the same reason as FMT013."
          previewPath? :=
            "\
Graduates on the same condition as FMT013, for section variables: at least 10 audited true positives \
with zero false positives on a corpus that does not already run `linter.unusedSectionVars`."
          examples :=
            #[{
                bad :=
                  "section\nvariable {α : Type} [inst : Inhabited α]\ntheorem refl_eq (a : α) : a = a := rfl\nend\n" }] }
      impl := .semantic unusedSectionVariable },
    { info :=
        { code := "FMT015"
          category := "naming"
          summary := "report a bound variable that resembles a nullary constructor"
          fixable := false
          defaultEnabled := false
          lifecycle := .preview
          explanation :=
            "\
A bound variable's name matches a nullary constructor in scope, surfaced from the compiler's \
`linter.constructorNameAsVariable` diagnostic — a pattern that reads as a constructor but binds a fresh \
variable. Report-only."
          previewPath? :=
            "\
Graduates when it produces at least 10 audited true positives on a corpus that exercises it AND its \
opinionation rate is measured — not just its false-positive rate. Of the ten \
preview rules this is the most likely to be true-but-unwanted: naming a binder after a nullary \
constructor can be deliberate and readable, so a clean false-positive count would not by itself show \
the rule is worth imposing."
          examples :=
            #[{
                bad :=
                  "inductive Light where\n  | red\n  | green\n\ndef f (red : Light) : Light := red\n" }] }
      impl := .semantic constructorNameVariable },
    { info :=
        { code := "FMT016"
          category := "layout"
          summary := "report a line wider than the configured line width"
          fixable := false
          defaultEnabled := false
          lifecycle := .stable
          explanation :=
            "\
A line is wider than `format.line-width`, counted in characters — the same unit Lean's layout \
engine counts when it decides where to break, so a line this rule reports is one the engine also \
considers over the margin. Report-only, and off by default: on unformatted source it repeats what \
`format` is about to fix, so run `format` first. What is left after that is the interesting case — a \
line lean-fmt could not break within the margin, either because the source pins its shape (a long \
string literal, a URL in a comment) or because lean-fmt found no break placement. Enable it in \
`lean-fmt.toml` under `[lint] extend-select = [\"FMT016\"]` to hold a formatted tree to its own margin."
          -- 109 characters, and one string token: `format` cannot shorten it, so the example
          -- shows the case worth reporting rather than one the formatter would have fixed.
          examples :=
            #[{
                bad :=
                  "def documentation : String := \"https://example.com/a/path/long/enough/that/no/break/placement/can/shorten/it\"\n" }] }
      impl := .source overlongLine }]

/-- Findings sort by position, then by code.

Concatenating each rule's output in registry order was once enough, because the default
rules were all `source`-tier and their findings happened to come out in position order. That was an
accident, and it does not survive a fold over mixed tiers: a `syntax` rule's findings would
otherwise follow every `source` rule's, wherever in the file they sit. Sorting on the code breaks
ties inside one position, so registry order — which means nothing — cannot decide output. -/
private def findingOrder (left right : Finding) : Bool :=
  if left.range.start != right.range.start then left.range.start < right.range.start
  else
    if left.range.stop != right.range.stop then left.range.stop < right.range.stop
    else left.code < right.code

/-- Every finding the available facts can produce, from `rules`, deterministically ordered.

**Selection is not applied here**, and must not be. `RulePlan.findings` projects afterwards, which
lets one cache entry serve any `--select` and keeps a rule's enablement out of every identity in the
product. A rule whose tier the facts cannot serve is skipped. That is not a silent omission:
`RulePlan.requiredTierOf` decided which facts to obtain, and it reads the same array.

The registry is a parameter here and fixed in `runRules`, so that a test can substitute one.
The engine's tier behavior — skipping, mixed-tier ordering, tie-breaking — is hard to exercise
through `ruleRegistry`, and shipping a fake rule for coverage is not an option, so tests pass
their own array. No production caller does, and none should: a rule set chosen per call site can
differ per call site. -/
def runRulesOf (rules : Array Rule) (facts : Facts) : Array Finding :=
  let findings :=
    rules.foldl (init := #[]) fun findings rule =>
      -- The skip is the third case, not a guard. A `facts.tier.satisfies rule.tier` test here
      -- would duplicate this match and could drift from it; the match cannot drift, because the
      -- constructor pair decides and the match is total.
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
def runRules (facts : Facts) : Array Finding :=
  runRulesOf ruleRegistry facts

/-- Run every rule the module's own source can answer. -/
def runSourceRules (normalized : String) (lineWidth : Nat) : Array Finding :=
  runRules (.source (SourceFacts.of normalized lineWidth))

/-! ## Import rules — declared here, produced elsewhere

The import family (`FMT003` duplicate, `FMT004` redundant, `FMT005` order/grouping) is
**not** in `ruleRegistry`, because it is not part of the linear-tier `RuleImpl` engine. Header
facts sit outside the `source ≤ syntax ≤ semantic` chain — the syntax projection drops the header —
and redundancy needs the Lake graph, which a `RuleImpl` cannot fetch (see the module note above).
`LeanFmt.Internal.Imports` and the `Project` graph operation produce their findings and merge them
into the report stream.

Their *identities* — code, category, summary, fixability, default — belong with every other rule's,
so that selection, `--select imports`, suppression, and `lean-fmt rules` treat them the same way
and cannot drift. They are declared here as `RuleInfo`s and added to `allRuleInfos`, which
`Config`'s selectors and the `rules` command read in place of `ruleRegistry` alone. -/

def importRuleInfos : Array RuleInfo :=
  #[{ code := "FMT003"
      category := "imports"
      summary := "remove a duplicate import"
      fixable := true
      defaultEnabled := true
      lifecycle := .stable
      explanation :=
        "\
The same module is imported twice in a header. The safe fix removes the later duplicate line. An exact \
repeat imports nothing new, so removing it preserves the module's environment and import order."
      examples :=
        #[{ bad := "import Lean\nimport Lean\n"
            good? := "import Lean\n" }] },
    { code := "FMT004"
      category := "imports"
      summary := "report an import made redundant by another import's transitive closure"
      fixable := false
      defaultEnabled := true
      lifecycle := .stable
      explanation :=
        "\
An import is already pulled in by another import's transitive closure, so it adds nothing to the \
module's environment. Report-only: whether the redundant line documents intent or should be removed is \
author judgment, and deciding it needs the Lake module graph, not this file alone. Illustrative \
(needs a multi-module project): importing both a module and a second module that already imports it \
flags the redundant one."
      -- Example-exempt (see `exampleExemptCodes`): redundancy is a cross-module graph fact,
      -- not a self-contained single-file snippet.
      examples := #[] },
    { code := "FMT005"
      category := "imports"
      summary := "report imports out of the configured import layout's order"
      fixable := false
      defaultEnabled := true
      lifecycle := .stable
      explanation :=
        "\
Imports are not in the order the configured `[format] import-layout` prescribes: module-name order \
within each blank-line group under `grouped`, or the canonical layout's order — modifier bucket, \
then prefix sub-block, then module path — under `canonical`. Report-only: reordering imports can \
change initialization order in principle, so the reordering is surfaced rather than applied \
automatically."
      examples := #[{ bad := "import Lean.Elab\nimport Lean.Data\n" }] }]

/-- The **reserved / retired** codes: codes that name no live rule but remain part of the
catalog namespace forever, so a future rule never silently reuses one and a legacy config or
suppression that still names one degrades gracefully rather than breaking. Each maps to a one-line disposition shown by a retirement notice and by `explain`.

**This table is empty, and that is a deliberate state, not a cleared one.** It held `FMT001` and
`FMT002` — the retired line-boundary and trailing-newline rules — until the pre-release renumbering
(docs/adding-a-rule.md §"Retiring a rule") shifted the live catalog down to start at `FMT001`. That renumbering
*reuses* two retired codes, which is exactly what this table exists to prevent; it was allowed
once, knowingly, because the package had no users and therefore no config or suppression comment
anywhere could be pointing at the old meanings. It is not a precedent. Once a real user exists, a
retired code is permanent again.

Consequence worth stating where someone will read it: with no entry here, the reserved branches in
`Config.selectorsValid` and `Suppression.apply` are live production code with **no test instance**.
They were covered by `FMT001` before, and inventing a placeholder retired rule to keep those tests
green would be a fake fixture proving nothing. They stay untested until a rule genuinely retires.

FMT900/FMT901 are **meta** self-diagnostics of the suppression engine (`Suppression.lean`), always
active and never selectable; they are not in this table but the catalog-invariant test forbids any
live rule from reusing them. -/
def reservedCodes : Array (String × String) :=
  #[]

/-- Whether `code` names a reserved/retired code. -/
def isReservedCode (code : String) : Bool :=
  reservedCodes.any (·.1 == code)

/-- The retirement disposition for a reserved code, if any. -/
def reservedDisposition? (code : String) : Option String :=
  (reservedCodes.find? (·.1 == code)).map (·.2)

/-- The **meta** self-diagnostic codes and what each one means. These are emitted by the
suppression projection (`Suppression.lean`), not by any rule: they are deliberately absent from
`ruleRegistry` because they are never selectable and never suppressible, and the catalog-invariant
test forbids a live rule from reusing them.

They are here so `explain` can answer for them. A user meets `FMT900` by seeing it in a report and
then looks it up; that lookup once returned `unknown rule: FMT900` and exit 2, which
is a false statement about a code the product had just printed. Not being in the registry is a fact
about selection, not a licence to deny the code exists. -/
def metaCodes : Array (String × String) :=
  #[("FMT900",
      "a suppression directive suppressed nothing — the finding it names was not reported, \
or the directive's scope holds no such finding. Always active, never selectable, and not itself \
suppressible. Carries a removal fix, which `check` shows and batch `fix` never applies."),
    ("FMT901",
      "a comment opens with the `lean-fmt:` sigil but does not parse as a directive, so it \
suppresses nothing. Always active, never selectable, and not itself suppressible. Its removal fix is \
`displayOnly`: deleting a broken directive may discard what its author meant.")]

/-- The description for a meta self-diagnostic code, if any. -/
def metaDescription? (code : String) : Option String :=
  (metaCodes.find? (·.1 == code)).map (·.2)

/-- Rules exempt from the "≥1 executable example" invariant, each for
a stated structural reason: FMT001/FMT002 flag an invisible/dangerous byte that cannot be embedded
verbatim in documentation, and FMT004 flags a cross-module graph fact that has no self-contained
single-file snippet. Their `explanation` carries an escaped/illustrative example instead. Every
other live rule must ship at least one executable example. -/
def exampleExemptCodes : Array String :=
  #["FMT001", "FMT002", "FMT004"]

/-- Every rule identity the product ships: the linear-tier engine's rules plus the import
rules. This is the single source `Config` selection and the `rules` command read, so a rule cannot
be selectable in one place and invisible in another. -/
def allRuleInfos : Array RuleInfo :=
  ruleRegistry.map (·.info) ++ importRuleInfos

/-- Whether `code` names an import rule (produced by `Imports`/`Project`, not the `RuleImpl` engine). -/
def isImportCode (code : String) : Bool :=
  importRuleInfos.any (·.code == code)

/-- The `lean-fmt rules` wire shape for the whole catalog: every engine rule with its derived
`input` tier, then every import rule. An import rule's per-file read is the surface header — a
**source**-level fact — so it projects onto `source`, the cheapest tier. The module graph FMT004
also consults sits outside the `source ≤ syntax ≤ semantic` chain (`Imports`): it is a run-level
input, not a deeper frontend tier, so it does not raise `input`. This is the one array
`rules --json` prints, so an import rule is as visible and selectable as any other. -/
def allRulesJson : Array Lean.Json :=
  ruleRegistry.map Lean.toJson ++
    importRuleInfos.map fun info =>
      Lean.Json.mkObj
        [("code", .str info.code), ("category", .str info.category), ("summary", .str info.summary),
          ("fixable", .bool info.fixable), ("defaultEnabled", .bool info.defaultEnabled),
          ("lifecycle", Lean.toJson info.lifecycle), ("input", .str "source")]

/-- The full metadata for one rule as JSON — every field, including `explanation` and
`examples` — the object `explain --json` and the documentation generator both consume, so they can
never disagree. `input`/`tier` is supplied by the caller (derived from
the `RuleImpl` for an engine rule, `source` for an import rule). -/
def ruleInfoJson (info : RuleInfo) (tier : String) : Lean.Json :=
  Lean.Json.mkObj
    [("code", .str info.code), ("category", .str info.category), ("summary", .str info.summary),
      ("fixable", .bool info.fixable), ("defaultEnabled", .bool info.defaultEnabled),
      ("lifecycle", Lean.toJson info.lifecycle), ("input", .str tier),
      ("explanation", .str info.explanation),
      ("replacement",
        match info.replacement? with
        | some r => .str r
        | none => .null),
      ("previewPath",
        match info.previewPath? with
        | some p => .str p
        | none => .null),
      ("examples",
        Lean.Json.arr
          (info.examples.map fun ex =>
            Lean.Json.mkObj
              [("bad", .str ex.bad),
                ("good",
                  match ex.good? with
                  | some g => .str g
                  | none => .null)]))]

/-- The `input`/tier wire string for a catalog code: the engine rule's derived tier if it
is in `ruleRegistry`, else `source` (the import family and any non-engine identity). -/
def tierWireOf (code : String) : String :=
  match ruleRegistry.find? (·.code == code) with
  | some rule => (Lean.toJson rule.tier).getStr?.toOption.getD "source"
  | none => "source"

/-- Look up a live rule's identity by code (engine rules and the import family). -/
def ruleInfoByCode? (code : String) : Option RuleInfo :=
  allRuleInfos.find? (·.code == code)

/-! ## Catalog rendering — one metadata source, every surface

`explain`, the generated rule pages, and the `lean-fmt.toml` schema are **projections over
the same `RuleInfo`**. Keeping the pure string-building here,
beside `allRulesJson`, stops them disagreeing, and it costs nothing at the compiler-plugin
boundary, because `LeanFmt.Rules` is not in the plugin closure (`docs/adding-a-rule.md`).
`LeanFmt.Cli` does the IO (printing, writing, drift-checking); it adds no content of its own. -/

private def lifecycleLabel : Lifecycle → String
  | .stable => "stable"
  | .preview => "preview"
  | .deprecated => "deprecated"

private def fixLabel (info : RuleInfo) : String :=
  if info.fixable then "fixable" else "report-only"

private def defaultLabel (info : RuleInfo) : String :=
  if info.defaultEnabled then "on" else "off"

/-- The human `explain RULE` text block: heading, metadata line,
explanation, each example, and the select/suppress/docs footer. -/
def explainText (info : RuleInfo) : String :=
  Id.run do
    let tier := tierWireOf info.code
    let mut out := s!"{info.code}  {info.summary}  [{lifecycleLabel info.lifecycle}]\n"
    out :=
      out ++
        s!"  category: {info.category}   tier: {tier}   fix: {fixLabel info}   default: {defaultLabel info}\n"
    match info.replacement? with
    | some r =>
      out := out ++ s!"  replacement: {r}\n"
    | none =>
      pure ()
    out := out ++ "\n  " ++ info.explanation ++ "\n"
    match info.previewPath? with
    | some p =>
      out := out ++ "\n  Path out of preview\n    " ++ p ++ "\n"
    | none =>
      pure ()
    for ex in info.examples do
      out := out ++ "\n  Example\n    - bad -\n"
      out :=
        out ++
          String.intercalate "\n" ((ex.bad.trimAsciiEnd.copy.splitOn "\n").map ("    " ++ ·)) ++
          "\n"
      match ex.good? with
      | some g =>
        out := out ++ "    - good -\n"
        out :=
          out ++ String.intercalate "\n" ((g.trimAsciiEnd.copy.splitOn "\n").map ("    " ++ ·)) ++
            "\n"
      | none =>
        pure ()
    out := out ++ s!"\n  Select:    --select {info.code}   |   --select {info.category}\n"
    out := out ++ s!"  Suppress:  -- lean-fmt: ignore[{info.code}]\n"
    out := out ++ s!"  Docs:      docs/rules/{info.code}.md\n"
    return out

/-- A fenced code block, language-tagged `lean`. -/
private def fence (body : String) : String :=
  "```lean\n" ++ body.trimAsciiEnd.copy ++ "\n```\n"

/-- One rule's generated markdown page (`docs/rules/FMT###.md`). Deterministic: pure over
`info`. Opens with a YAML frontmatter block carrying the machine-readable fields (code, category,
tier, lifecycle, fix, default, replacement), so a tool — the executable-example harness among them
— reads the catalog straight from the pages without re-deriving it. The
body below repeats the same facts for a human reader. -/
def rulePageMarkdown (info : RuleInfo) : String :=
  Id.run do
    let tier := tierWireOf info.code
    let mut out := "---\n"
    out := out ++ s!"code: {info.code}\n"
    out := out ++ s!"category: {info.category}\n"
    out := out ++ s!"tier: {tier}\n"
    out := out ++ s!"lifecycle: {lifecycleLabel info.lifecycle}\n"
    out := out ++ s!"fix: {fixLabel info}\n"
    out := out ++ s!"default: {defaultLabel info}\n"
    match info.replacement? with
    | some r =>
      out := out ++ s!"replacement: {r}\n"
    | none =>
      pure ()
    out := out ++ "---\n\n"
    out := out ++ s!"# {info.code} — {info.summary}\n\n"
    out := out ++ s!"- **Lifecycle:** {lifecycleLabel info.lifecycle}\n"
    out := out ++ s!"- **Category:** `{info.category}`\n"
    out := out ++ s!"- **Tier:** `{tier}`\n"
    out := out ++ s!"- **Fix:** {fixLabel info}\n"
    out := out ++ s!"- **Default:** {defaultLabel info}\n"
    match info.replacement? with
    | some r =>
      out := out ++ s!"- **Replacement:** `{r}`\n"
    | none =>
      pure ()
    out := out ++ "\n" ++ info.explanation ++ "\n"
    match info.previewPath? with
    | some p =>
      out := out ++ "\n## Path out of preview\n\n" ++ p ++ "\n"
    | none =>
      pure ()
    for ex in info.examples do
      out := out ++ "\n## Example\n\nBad:\n\n" ++ fence ex.bad
      match ex.good? with
      | some g =>
        out := out ++ "\nGood:\n\n" ++ fence g
      | none =>
        pure ()
    out := out ++ s!"\n## Using this rule\n\n"
    out := out ++ s!"- Select: `--select {info.code}` or `--select {info.category}`\n"
    out := out ++ s!"- Suppress: `-- lean-fmt: ignore[{info.code}]`\n"
    return out

/-- The generated catalog index (`docs/rules/index.md`): a table of every live rule
grouped by category, sorted by code within a group, plus the retired-code table.
Deterministic. -/
def catalogIndexMarkdown : String :=
  Id.run do
    let mut out := "# Rule catalog\n\n"
    out :=
      out ++ "Generated from the rule registry (`LeanFmt/Rules.lean`); do not edit by hand.\n\n"
    let categories :=
      (allRuleInfos.map (·.category)).foldl (init := #[]) fun acc c =>
        if acc.contains c then acc else acc.push c
    for category in categories.qsort (· < ·) do
      out := out ++ s!"## {category}\n\n"
      out :=
        out ++ "| Code | Lifecycle | Default | Fix | Summary |\n| --- | --- | --- | --- | --- |\n"
      let rules := (allRuleInfos.filter (·.category == category)).qsort (·.code < ·.code)
      for info in rules do
        out :=
          out ++
            s!"| [{info.code}]({info.code}.md) | {lifecycleLabel info.lifecycle} | \
        {defaultLabel info} | {fixLabel info} | {info.summary} |\n"
      out := out ++ "\n"
    out := out ++ "## Retired codes\n\n"
    out :=
      out ++
        "These codes name no live rule; they are reserved so a selector or suppression that \
    still references one keeps working.\n\n| Code | Disposition |\n| --- | --- |\n"
    for (code, disposition) in reservedCodes do
      out := out ++ s!"| {code} | {disposition} |\n"
    out :=
      out ++
        "\nThe machine-readable configuration schema is `schema.json`, generated from the same \
    registry.\n"
    return out

/-- The selector vocabulary `selectorsValid` (`Config.lean`) accepts, in one deterministic
order: `all`, `default`, then categories, live codes, and reserved codes, each sorted. The
generated schema enum and `selectorsValid` both read `allRuleInfos`/`reservedCodes`, so the
accepted tokens and the documented ones cannot drift. -/
def selectorVocabulary : Array String :=
  let categories :=
    ((allRuleInfos.map (·.category)).foldl (init := #[]) fun acc c =>
          if acc.contains c then acc else acc.push c).qsort
      (· < ·)
  let codes := (allRuleInfos.map (·.code)).qsort (· < ·)
  let reserved := (reservedCodes.map (·.1)).qsort (· < ·)
  #["all", "default"] ++ categories ++ codes ++ reserved

/-- The generated JSON-schema fragment for `lean-fmt.toml`:
every config key `Config.lean`'s `parseFile` accepts, with each selector-valued array constrained
to `selectorVocabulary` and `preview` to a boolean. Built as a byte-stable pretty string beside the
rule pages — deterministic, so `docs --check` drift-checks it like every other page. -/
def catalogSchemaJson : String :=
  let sel := "{ \"type\": \"array\", \"items\": { \"$ref\": \"#/$defs/selector\" } }"
  let deprecated :=
    "{ \"type\": \"array\", \"items\": { \"$ref\": \"#/$defs/selector\" }, " ++
      "\"deprecated\": true, \"description\": \"moved to [lint]; still accepted, see $defs/migration\" }"
  let enumBody :=
    String.intercalate ",\n" (selectorVocabulary.toList.map fun s => "      \"" ++ s ++ "\"")
  let lintProperties :=
    "      \"select\": " ++ sel ++ ",\n" ++ "      \"extend-select\": " ++ sel ++ ",\n" ++
      "      \"ignore\": " ++
      sel ++
      ",\n" ++
      "      \"fixable\": " ++
      sel ++
      ",\n" ++
      "      \"unfixable\": " ++
      sel ++
      ",\n" ++
      "      \"extend-fixable\": " ++
      sel ++
      ",\n" ++
      "      \"extend-safe-fixes\": " ++
      sel ++
      ",\n" ++
      "      \"extend-unsafe-fixes\": " ++
      sel ++
      ",\n" ++
      "      \"per-file-ignores\": { \"type\": \"object\", \"additionalProperties\": " ++
      sel ++
      " }\n"
  "{\n" ++ "  \"$schema\": \"http://json-schema.org/draft-07/schema#\",\n" ++
    "  \"$id\": \"lean-fmt.toml\",\n" ++
    "  \"title\": \"lean-fmt configuration\",\n" ++
    "  \"description\": \"Generated from the rule registry (LeanFmt/Rules.lean); do not edit by hand.\",\n" ++
    "  \"type\": \"object\",\n" ++
    "  \"additionalProperties\": false,\n" ++
    "  \"properties\": {\n" ++
    "    \"include\": { \"type\": \"array\", \"items\": { \"type\": \"string\" } },\n" ++
    "    \"exclude\": { \"type\": \"array\", \"items\": { \"type\": \"string\" } },\n" ++
    "    \"extend\": { \"type\": \"string\" },\n" ++
    "    \"force-exclude\": { \"type\": \"boolean\" },\n" ++
    "    \"respect-gitignore\": { \"type\": \"boolean\" },\n" ++
    "    \"preview\": { \"type\": \"boolean\" },\n" ++
    "    \"format\": {\n" ++
    "      \"type\": \"object\",\n" ++
    "      \"additionalProperties\": false,\n" ++
    "      \"properties\": {\n" ++
    "        \"line-width\": { \"type\": \"integer\", \"minimum\": 1, \"maximum\": 1000 },\n" ++
    "        \"pinned-comments\": { \"type\": \"array\", \"items\": { \"type\": \"string\", \"minLength\": 1 } },\n" ++
    "        \"reflow-comments\": { \"type\": \"boolean\" },\n" ++
    "        \"declaration-body\": { \"type\": \"string\", \"enum\": [\"next-line\", \"same-line\"] },\n" ++
    "        \"declaration-where\": { \"type\": \"string\", \"enum\": [\"same-line\", \"next-line\"] },\n" ++
    "        \"import-layout\": { \"type\": \"string\", \"enum\": [\"grouped\", \"canonical\"] },\n" ++
    "        \"import-groups\": { \"type\": \"array\", \"items\": { \"type\": \"string\", \"minLength\": 1 } },\n" ++
    "        \"magic-trailing-comma\": { \"type\": \"string\", \"enum\": [\"respect\", \"ignore\"] }\n" ++
    "      }\n" ++
    "    },\n" ++
    "    \"lint\": {\n" ++
    "      \"type\": \"object\",\n" ++
    "      \"additionalProperties\": false,\n" ++
    "      \"properties\": {\n" ++
    lintProperties ++
    "      }\n" ++
    "    },\n" ++
    "    \"select\": " ++
    deprecated ++
    ",\n" ++
    "    \"extend-select\": " ++
    deprecated ++
    ",\n" ++
    "    \"ignore\": " ++
    deprecated ++
    ",\n" ++
    "    \"fixable\": " ++
    deprecated ++
    ",\n" ++
    "    \"unfixable\": " ++
    deprecated ++
    ",\n" ++
    "    \"extend-fixable\": " ++
    deprecated ++
    ",\n" ++
    "    \"extend-safe-fixes\": " ++
    deprecated ++
    ",\n" ++
    "    \"extend-unsafe-fixes\": " ++
    deprecated ++
    ",\n" ++
    "    \"per-file-ignores\": { \"type\": \"object\", \"additionalProperties\": " ++
    sel ++
    ", " ++
    "\"deprecated\": true }\n" ++
    "  },\n" ++
    "  \"$defs\": {\n" ++
    "    \"migration\": {\n" ++
    "      \"description\": \"A linter key at the top level is the pre-[lint] spelling; it still works \
    and emits a deprecation notice, and setting the same key in both places is an error.\"\n" ++
    "    },\n" ++
    "    \"selector\": {\n" ++
    "      \"description\": \"a live rule code, a category, a reserved code, or the words all/default\",\n" ++
    "      \"enum\": [\n" ++
    enumBody ++
    "\n" ++
    "      ]\n" ++
    "    }\n" ++
    "  }\n" ++
    "}\n"

/-- Every generated documentation file as `(relative path, content)` under `docs/rules/`,
in a deterministic order. The `docs` command writes these; the drift check regenerates and
compares. -/
def catalogDocs : Array (String × String) :=
  #[("index.md", catalogIndexMarkdown), ("schema.json", catalogSchemaJson)] ++
    (allRuleInfos.qsort (·.code < ·.code)).map fun info =>
      (s!"{info.code}.md", rulePageMarkdown info)

end LeanFmt.Internal
