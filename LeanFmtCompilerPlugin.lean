module

/- Loading this module registers the compiler callback. It is deliberately excluded from the
ordinary LeanFmt root so application imports cannot change frontend behavior. -/
import LeanFmt.CompilerPlugin
