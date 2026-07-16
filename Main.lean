module

import all LeanFmt.Cli

public unsafe def main (args : List String) : IO UInt32 :=
  LeanFmt.Internal.Cli.runCli args
