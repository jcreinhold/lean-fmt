def build (n : Nat) : String := Id.run do
  let mut out := ""
  for i in [0:n] do
    out := out ++ s!"tests/some/Path{i}.lean:12:34: FMT005 duplicate import of Some.Module\n"
  return out

def main : IO Unit := do
  for n in [1000, 10000, 100000, 400000] do
    let started ← IO.monoNanosNow
    let s := build n
    let finished ← IO.monoNanosNow
    IO.println s!"n={n} bytes={s.utf8ByteSize} ms={(finished - started) / 1000000}"
