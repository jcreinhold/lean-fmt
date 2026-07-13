import LeanFmt.Capability
import LeanFmt.Frontend
import LeanFmt.Protocol
import LeanFmt.Rules

/-!
# LeanFmt

Root module of the `LeanFmt` Lean capability package. It re-exports the capability
surface that the Lean-linked worker child loads: the identity/self-check commands
(`LeanFmt.Capability`), the source-snapshot parse command (`LeanFmt.Frontend`), the
edit-protocol JSON constructors (`LeanFmt.Protocol`), and the stable rule-id registry
mirror (`LeanFmt.Rules`). Rule *logic* is added in later prompts.
-/
