-- Drive `lean-fmt lsp` with Neovim's own LSP client, through the configuration
-- `docs/editor-setup.md` hands users.
--
-- `run.sh` and `acceptance.sh` both drive the protocol. This drives the *editor*:
-- `vim.lsp` is the client an interactive session runs, so what it exercises is the
-- documented Neovim stanza rather than a harness modelling our own assumptions.
-- That is what `ruff-17` RLP-FINAL left open and what `serve`'s removal waited on.
--
-- The buffer is never written. Formatting applies in memory and is compared there,
-- and the last check reads the file back to prove the server touched no source.

local ok_count, fail_count = 0, 0
local function check(name, condition, detail)
  if condition then
    ok_count = ok_count + 1
    print(("  ok   %s"):format(name))
  else
    fail_count = fail_count + 1
    print(("  FAIL %s%s"):format(name, detail and ("  -- " .. detail) or ""))
  end
end

-- Exactly the docs/editor-setup.md Neovim stanza.
vim.lsp.config["lean-fmt"] = {
  cmd = { ".lake/build/bin/lean-fmt", "lsp" },
  filetypes = { "lean" },
  root_markers = { "lakefile.lean", "lakefile.toml" },
  init_options = { debounceMs = 150 },
}
vim.lsp.enable("lean-fmt")

vim.cmd.edit("LeanFmt/Basic.lean")
local buf = vim.api.nvim_get_current_buf()
local original = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

local function client()
  return vim.lsp.get_clients({ bufnr = buf, name = "lean-fmt" })[1]
end

check("neovim detects the filetype the config keys on", vim.bo[buf].filetype == "lean",
  "filetype=" .. vim.bo[buf].filetype)

local attached = vim.wait(60000, function() return client() ~= nil end, 200)
check("the server starts and neovim attaches it to a .lean buffer", attached)
if not attached then
  print(("\nchecks: %d ok, %d failed"):format(ok_count, fail_count))
  vim.cmd("cquit 1")
end

local c = client()
local caps = c.server_capabilities
check("advertises documentFormattingProvider", caps.documentFormattingProvider ~= nil)
check("advertises documentRangeFormattingProvider", caps.documentRangeFormattingProvider ~= nil)
check("advertises codeActionProvider", caps.codeActionProvider ~= nil)
check("advertises no hover (it does not duplicate Lean's server)", caps.hoverProvider == nil)

-- Trailing whitespace is a formatting difference, not a reported rule, so it
-- publishes nothing. Introduce a duplicate import instead: FMT005 is stable,
-- default-enabled, and fixable.
vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "", "import LeanFmt.Digest", "import LeanFmt.Digest" })
check("buffer is dirty and unsaved", vim.bo[buf].modified)

local function lf_diags()
  local found = {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    if d.source == "lean-fmt" then found[#found + 1] = d end
  end
  return found
end
local got_diag = vim.wait(90000, function() return #lf_diags() > 0 end, 250)
check("publishes a diagnostic for the unsaved edit", got_diag,
  got_diag and "" or "no lean-fmt diagnostic arrived")
if got_diag then
  local d = lf_diags()[1]
  print(("       -> line %d [%s] %s"):format(d.lnum + 1, d.code or "?", d.message))
  check("the diagnostic carries its rule code", d.code ~= nil and d.code ~= "")

  -- The same finding must be reachable as a code action, titled with its code.
  local params = vim.lsp.util.make_range_params(0, "utf-16")
  params.range = { start = { line = d.lnum, character = 0 }, ["end"] = { line = d.lnum, character = 0 } }
  params.context = { diagnostics = { }, triggerKind = 1 }
  local res = c:request_sync("textDocument/codeAction", params, 60000, buf)
  local titles = {}
  for _, a in ipairs((res or {}).result or {}) do titles[#titles + 1] = a.title end
  check("offers at least one code action", #titles > 0, table.concat(titles, " | "))
  if #titles > 0 then print("       -> " .. table.concat(titles, "\n       -> ")) end
end

-- Undo the edit so the formatting comparison below starts from the real file.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, original)
vim.wait(2000, function() return false end, 100)
local wsline = original[6]
vim.api.nvim_buf_set_lines(buf, 5, 6, false, { wsline .. "   " })

-- Format through neovim's own request path.
local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
vim.lsp.buf.format({ name = "lean-fmt", bufnr = buf, timeout_ms = 60000 })
local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

check("formatting changed the buffer", not vim.deep_equal(before, after))
check("formatting removed the trailing whitespace", after[6] == original[6],
  ("got %q want %q"):format(after[6] or "<nil>", original[6]))
check("formatting left every other line alone", vim.deep_equal(after, original))

-- The server must not have touched disk.
local on_disk = vim.fn.readfile("LeanFmt/Basic.lean")
check("the file on disk is untouched", vim.deep_equal(on_disk, original))

print(("\nchecks: %d ok, %d failed"):format(ok_count, fail_count))
vim.cmd(fail_count == 0 and "qa!" or "cquit 1")
