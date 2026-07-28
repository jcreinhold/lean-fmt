module

namespace ArtifactLayout

syntax "twice " term : term

macro_rules
  | `(twice $value) => `($value + $value)

def value(a:Nat):Nat:=twice a

end ArtifactLayout
