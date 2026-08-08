import VersoManual
import Manual

open Verso.Genre Manual

def config : RenderConfig where
  emitTeX := false
  emitHtmlSingle := .no
  emitHtmlMulti := .immediately
  htmlDepth := 2
  sourceLink := some "https://github.com/jcreinhold/lean-fmt"
  issueLink := some "https://github.com/jcreinhold/lean-fmt/issues"

def main := manualMain (%doc Manual) (config := config)
