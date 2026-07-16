module

import all LeanFmt.Application

public unsafe def main (args : List String) : IO UInt32 :=
  LeanFmt.Internal.Application.runCli args
