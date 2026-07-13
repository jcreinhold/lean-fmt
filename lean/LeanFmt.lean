import LeanFmt.Capability
import LeanFmt.Frontend
import LeanFmt.Protocol

/-!
# LeanFmt

Root module of the `LeanFmt` Lean capability package. It re-exports the capability
surface that the Lean-linked worker child loads: the identity/self-check commands
(`LeanFmt.Capability`), the source-snapshot parse command (`LeanFmt.Frontend`), and the
edit-protocol JSON constructors (`LeanFmt.Protocol`). Rule commands are added in later
prompts.
-/
