module

import Fixture.Notation
import Fixture.Wide

/-- Uses `Notation`'s syntax. Its own bytes never change in the notation experiment. -/
def userValue : Nat := 3 <+> wideValue
