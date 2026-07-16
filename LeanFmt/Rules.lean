module

import all LeanFmt.ArtifactModel
import Lean

namespace LeanFmt.Internal

private def commandShape (stx : Lean.Syntax) : CommandShape :=
  let range? := stx.getRange?.map fun range =>
    { start := range.start.byteIdx, stop := range.stop.byteIdx }
  { kind := stx.getKind.toString, range? }

def projectCommands (commands : Array Lean.Syntax) : Array CommandShape :=
  commands.map commandShape

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
      let lineStop := if index > lineStart && source.get! (index - 1) == 0x0d then
        index - 1
      else
        index
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
file. Configuration is supplied by traced Lean options, not an unverified external digest. -/
def runRules (source : String) (checkTrailingWhitespace := true) : Array Finding :=
  let bytes := source.toUTF8
  (if checkTrailingWhitespace then trailingWhitespace bytes else #[]) ++ finalNewline bytes

end LeanFmt.Internal
