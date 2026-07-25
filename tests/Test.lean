module

public import Test.Fixture
public import Test.Golden
public import Test.Harness
public import Test.Json
public import Test.LspClient
public import Test.Proc

/-!
# The shared test library

One import (`import Test`) gives a suite the whole harness. The pieces are separate modules so the
import graph records what a suite actually uses; this root exists so the lakefile can glob one
namespace and suites can write one import line.
-/
