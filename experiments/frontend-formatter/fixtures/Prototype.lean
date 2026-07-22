module

import PrototypeSyntax

open FormatterPrototypeSyntax

/- block payload remains byte-for-byte owned by this command -/
prototype_command extensionValue := prototype_term(1, 2, 3, 4, 5, 6, 7, 8)

prototype_command extensionValue2 := prototype_term(1, 2, 3, 4, 5, 6, 7, 8)

def nestedExtension := prototype_term(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)

def short := 1

def tacticExtension : True := by
  -- tactic payload remains owned by the original command
  prototype_exact True.intro

def widthProbe := List.map (fun value => value + 1) [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

#exit
verbatim tail remains untouched
