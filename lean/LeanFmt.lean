import LeanFmt.Capability
import LeanFmt.Frontend

/-!
# LeanFmt

Root module of the `LeanFmt` Lean capability package. It re-exports the capability
surface that the Lean-linked worker child loads: the identity/self-check commands
(`LeanFmt.Capability`) and the source-snapshot parse command (`LeanFmt.Frontend`).
Edit and rule commands are added in later prompts.
-/
