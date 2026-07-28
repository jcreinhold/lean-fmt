module

import all LeanFmt.Cli

/-! The `lean-fmt` executable: argument vector in, exit code out. Everything else is `LeanFmt.Cli`. -/

public unsafe def main (args : List String) : IO UInt32 :=
  LeanFmt.Internal.Cli.runCli args
