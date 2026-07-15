module

import Lean

open Lean Elab Command

namespace LeanFmtProbePlugin

private def syntaxRangeJson (stx : Syntax) : Json :=
  match stx.getRange? with
  | some range => Json.mkObj
      [ ("kind", Json.str stx.getKind.toString)
      , ("start", toJson range.start.byteIdx)
      , ("stop", toJson range.stop.byteIdx) ]
  | none => Json.mkObj [("kind", Json.str stx.getKind.toString)]

private def writeArtifact (commands : Array Syntax) : CommandElabM Unit := do
  let some output ← IO.getEnv "LEAN_FMT_PROBE_ARTIFACT"
    | return
  let source := (← getFileMap).source
  let artifact := Json.mkObj
    [ ("schema", Json.str "lean-fmt.compiler-probe.v1")
    , ("source", Json.str (← getFileName))
    , ("source_bytes", toJson source.utf8ByteSize)
    , ("source_hash", toJson (hash source))
    , ("commands", Json.arr (commands.map syntaxRangeJson)) ]
  IO.FS.writeFile output artifact.compress

initialize addModuleLinter {name := `leanFmtProbe, run := writeArtifact}

end LeanFmtProbePlugin
