module

public import Test

/-!
# The editor suite

Port of `tests/lsp/editor.sh`: the editor check. `suite-lsp` and `suite-lsp-acceptance` drive the
protocol; this drives a real editor's client against it, the one thing neither of them can do. The
client checks live in `tests/lsp/editor.lua` and stay there — like
`tests/formatter/candidate.py`, the value of the check is that the adversary is the *real*
`vim.lsp`, not a Lean model of it.

It needs Neovim 0.11 or newer on PATH, so it skips rather than fails when Neovim is absent or too
old, exactly as the script did.

Lane: exclusive+slow — a real editor process over a live server.
-/

open LeanFmt.Test

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  let nvim ← runProc "sh" #["-c", "command -v nvim"]
  if nvim.exitCode != 0 then
    IO.println "lean-fmt editor check SKIPPED (no nvim on PATH)"
    return 0
  -- `--clean -u NONE`, so the developer's own configuration cannot decide the result. The version
  -- floor is the one the script enforced: 0.11 for `vim.lsp.config`.
  let version ← expectExit 0 "nvim --version" "nvim" #["--version"]
  let firstLine := (version.stdout.splitOn "\n").head?.getD ""
  let parts := (((firstLine.drop 6).takeWhile (· != ' ')).toString).splitOn "."
  let (major, minor) := (((parts[0]?.getD "0").toNat?).getD 0, ((parts[1]?.getD "0").toNat?).getD 0)
  if major == 0 && minor < 11 then
    IO.println s!"lean-fmt editor check SKIPPED (nvim {major}.{minor}, needs 0.11+ for \
      vim.lsp.config)"
    return 0
  let cases : Array Case := #[
    { name := "neovim-client", run := do
        discard <| expectExit 0 "the editor's client disagreed with the server" "nvim"
          #["--headless", "--clean", "-u", "NONE", "-l", "tests/lsp/editor.lua"]
          (cwd? := some root) (env := #[("LEAN_NUM_THREADS", some "1")])
          (timeoutMs := some 600000) }
  ]
  runCases "editor" cases args
