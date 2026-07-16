module

/- A compiler-plugin probe for `RLS-SPEC`.

The parse-only oracle in `RoundTrip.lean` cannot parse a file that declares its own syntax, because
a token table built from imports alone does not contain the file's own `syntax`/`notation`
declarations. This probe answers the same losslessness question from the one position that does
have the right token table: a module linter running inside the compiler, after elaboration.

It deliberately reconstructs from exactly what `Lean.Elab.Command.ModuleLinter` is handed, so the
report measures the real plugin boundary rather than a convenient one. -/

import Lean

open Lean Elab Command

namespace LosslessProbe

private partial def spanOf (stx : Syntax) : Option (Nat × Nat) :=
  match stx with
  | .missing => none
  | .node _ _ args => args.foldl (init := none) fun acc arg =>
    match acc, spanOf arg with
    | none, span => span
    | span, none => span
    | some (lo, _), some (_, hi) => some (lo, hi)
  | .atom info _ | .ident info _ _ _ =>
    match info with
    | .original leading _ trailing _ => some (leading.startPos.byteIdx, trailing.stopPos.byteIdx)
    | _ => none

private partial def reconstruct (stx : Syntax) (acc : String) : String :=
  match stx with
  | .missing => acc
  | .node _ _ args => args.foldl (fun acc arg => reconstruct arg acc) acc
  | .atom info val =>
    match info with
    | .original leading _ trailing _ => acc ++ leading.toString ++ val ++ trailing.toString
    | _ => acc
  | .ident info rawVal _ _ =>
    match info with
    | .original leading _ trailing _ => acc ++ leading.toString ++ rawVal.toString ++ trailing.toString
    | _ => acc

private partial def countLeaves (stx : Syntax) (counts : Nat × Nat × Nat) : Nat × Nat × Nat :=
  let (original, synthetic, missing) := counts
  match stx with
  | .missing => (original, synthetic, missing + 1)
  | .node _ _ args => args.foldl (fun acc arg => countLeaves arg acc) counts
  | .atom info _ | .ident info _ _ _ =>
    match info with
    | .original .. => (original + 1, synthetic, missing)
    | .synthetic .. => (original, synthetic + 1, missing)
    | .none => (original, synthetic, missing)

private def probe (commands : Array Syntax) : CommandElabM Unit := do
  let fileMap ← getFileMap
  let source := fileMap.source
  let rebuilt := commands.foldl (fun acc stx => reconstruct stx acc) ""
  let counts := commands.foldl (fun acc stx => countLeaves stx acc) (0, 0, 0)
  let (original, synthetic, missing) := counts
  let covered := commands.foldl (init := (none : Option (Nat × Nat))) fun acc stx =>
    match acc, spanOf stx with
    | none, span => span
    | span, none => span
    | some (lo, _), some (_, hi) => some (lo, hi)
  let coveredText := match covered with
    | some (lo, hi) => s!"[{lo},{hi})"
    | none => "none"
  logInfo m!"lossless-probe module={(← getEnv).mainModule} \
source_bytes={source.utf8ByteSize} commands={commands.size} \
rebuilt_bytes={rebuilt.utf8ByteSize} rebuilt_eq_source={rebuilt == source} \
command_span={coveredText} leaves_original={original} leaves_synthetic={synthetic} \
leaves_missing={missing} prefix_missing={source.utf8ByteSize - rebuilt.utf8ByteSize}"

initialize addModuleLinter { name := `losslessProbe, run := probe }

end LosslessProbe
