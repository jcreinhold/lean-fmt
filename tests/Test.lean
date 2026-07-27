module

public import Test.Analyze
public import Test.Fixture
public import Test.Golden
public import Test.Harness
public import Test.Json
public import Test.LspClient
public import Test.Oracle
public import Test.Proc

/-!
# The shared test library

`import Test` gives a suite the whole harness. The pieces stay separate modules so the import graph
records what each suite uses; this root lets the lakefile glob one namespace and suites write one
import line.
-/
