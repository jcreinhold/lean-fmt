module

public import LeanFmt.Analysis
public import LeanFmt.Application
public import LeanFmt.ArtifactStore
public import LeanFmt.Cache
public import LeanFmt.Cli
public import LeanFmt.Comments
public import LeanFmt.Config
public import LeanFmt.Discovery
public import LeanFmt.Doc
public import LeanFmt.Edit
public import LeanFmt.Formatter.NativeLayout
public import LeanFmt.Imports
public import LeanFmt.LanguageServer
public import LeanFmt.Rules
public import LeanFmt.Suppression
public import Test

import all LeanFmt.Analysis
import all LeanFmt.Application
import all LeanFmt.ArtifactStore
import all LeanFmt.Cache
import all LeanFmt.Cli
import all LeanFmt.Comments
import all LeanFmt.Config
import all LeanFmt.Discovery
import all LeanFmt.Doc
import all LeanFmt.Edit
import all LeanFmt.Formatter.NativeLayout
import all LeanFmt.Imports
import all LeanFmt.LanguageServer
import all LeanFmt.Rules
import all LeanFmt.Suppression

import Lean.Data.Lsp

open LeanFmt LeanFmt.Internal

namespace LeanFmt.Test.Unit.Fixtures

/-! ## Fixtures

One source text and the projection and module artifact that describe it exactly, shared by the unit
modules that need a valid artifact to mutate. They are written out by hand rather than produced by a
run, so a case can assert against a projection the product did not choose. -/

/-- The `format.line-width` a fact view gets when the case is not about the margin: the product's
own default, so a case reads the same width a user's first run does. A case that *is* about the
margin passes its own width. Spelled once because the alternative — a literal per call site — lets
two cases in one file disagree about what "the default" is. -/
private def defaultLineWidth : Nat :=
  ({} : LeanFmt.Internal.FormatConfig).lineWidth

/- The projection of `def x := 1\n`, written by hand so the tiling invariant is legible: every
token's span and trivia runs abut, covering `[headerStop, terminalStop)` exactly once.

    byte 0    3 4 5 6  8 9 10 11
         |def | |x| |:=| |1 |\n|
-/
private def fixtureSourceText : String :=
  "def x := 1\n"

private def fixtureLosslessSource (mainModule := "Test") : LosslessSource :=
  { schema := losslessSourceSchema
    mainModule
    normalizedBytes := fixtureSourceText.utf8ByteSize
    normalizedDigest := Digest.ofString fixtureSourceText
    headerStop := 0
    terminalStop := fixtureSourceText.utf8ByteSize
    kinds := #["Lean.Parser.Command.declaration"]
    nodes := #[{ kind := 0, parent := none, range := { start := 0, stop := 10 } }]
    tokens :=
      #[{ node := 0, start := 0, stop := 3, trailing := #[{ kind := .whitespace, stop := 4 }] },
        { node := 0, start := 4, stop := 5, trailing := #[{ kind := .whitespace, stop := 6 }] },
        { node := 0, start := 6, stop := 8, trailing := #[{ kind := .whitespace, stop := 9 }] },
        { node := 0, start := 9, stop := 10, trailing := #[{ kind := .whitespace, stop := 11 }] }] }

private def fixtureArtifact : ModuleArtifact :=
  { schema := artifactSchema
    mainModule := "Test"
    normalizedBytes := fixtureSourceText.utf8ByteSize
    normalizedDigest := Digest.ofString fixtureSourceText
    syntaxData :=
      { kinds := #[`Lean.Parser.Command.declaration]
        entries :=
          #[.node .none 0 4, .atom (.original 0 0 3 4) none, .atom (.original 4 4 5 6) none,
            .atom (.original 6 6 8 9) none, .atom (.original 9 9 10 11) none,
            .atom (.synthetic fixtureSourceText.utf8ByteSize fixtureSourceText.utf8ByteSize true)
              (some "")]
        commands :=
          #[{ entry := 0
              range := ⟨0, fixtureSourceText.utf8ByteSize⟩ }]
        terminal := 5 } }

end LeanFmt.Test.Unit.Fixtures
