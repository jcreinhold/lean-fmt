module

namespace NativeLayoutSourceData

syntax (name := bracketedTerm) "bracketed(" term ")" : term

macro_rules
  | `(bracketed($value:term)) => `($value)

macro "source_quote" value:term : term => `($value + $value)

def interpolation (name : String) : String := s!"hello {name}"

def multiline : String := "first\nsecond"

def quotation : Nat := source_quote bracketed(2)

end NativeLayoutSourceData
