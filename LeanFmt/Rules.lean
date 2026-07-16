module

import all LeanFmt.ArtifactModel
import Lean

namespace LeanFmt.Internal

inductive RuleInput where
  | source
  | syntax
  deriving BEq, Lean.ToJson

structure RuleInfo where
  code : String
  category : String
  summary : String
  fixable : Bool
  defaultEnabled : Bool
  input : RuleInput
  deriving BEq, Lean.ToJson

def ruleRegistry : Array RuleInfo := #[
  {
    code := "FMT001"
    category := "text"
    summary := "remove trailing horizontal whitespace"
    fixable := true
    defaultEnabled := true
    input := .source
  },
  {
    code := "FMT002"
    category := "text"
    summary := "require a final newline"
    fixable := true
    defaultEnabled := true
    input := .source
  }
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
    fix? := some { range, replacement := "" }
  }

private def trailingWhitespace (source : ByteArray) : Array Finding := Id.run do
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

private def finalNewline (source : ByteArray) : Array Finding :=
  if source.isEmpty || source.get! (source.size - 1) == 0x0a then
    #[]
  else
    let range := { start := source.size, stop := source.size }
    #[{
      code := "FMT002"
      severity := .warning
      message := "file must end with a newline"
      range
      fix? := some { range, replacement := "\n" }
    }]

/-- Run configured source-local rules after the exact frontend has successfully elaborated the
file. Configuration is supplied by traced Lean options, not an unverified external digest.

`normalized` must be `(LosslessSource.normalize raw).1`. Every finding's range indexes it, which is
the same string `LosslessSource` indexes; a caller passing raw bytes would produce an artifact whose
two halves are measured in different coordinate systems. Accepted source cannot contain an isolated
`\r`, so after normalization no carriage return survives for a line-oriented rule to consider. -/
def runRules (normalized : String) (checkTrailingWhitespace := true) : Array Finding :=
  let bytes := normalized.toUTF8
  (if checkTrailingWhitespace then trailingWhitespace bytes else #[]) ++ finalNewline bytes

/-- Build the artifact for one accepted module.

This is the only artifact producer. Exact analysis and the compiler plugin reach it with the same
arguments, so they cannot drift into emitting different artifacts for the same module — which is
what makes the facet a sound cache of the exact frontend rather than a second opinion. -/
def ModuleArtifact.ofParsedModule (mainModule normalized : String)
    (commands : Array Lean.Syntax) (terminal? : Option Lean.Syntax)
    (checkTrailingWhitespace : Bool) : ModuleArtifact := {
  schema := artifactSchema
  trailingWhitespace := checkTrailingWhitespace
  source := LosslessSource.ofSource mainModule normalized commands terminal?
  findings := runRules normalized checkTrailingWhitespace
}

end LeanFmt.Internal
