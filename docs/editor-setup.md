# Editor setup

**Audience: anyone running lean-fmt.**

`lean-fmt lsp` speaks the Language Server Protocol over stdio. It offers formatting, range formatting,
formatting-derived code actions, and diagnostics — and nothing else. It runs *alongside* Lean's own language server, not
instead of it.

```sh
lake build
.lake/build/bin/lean-fmt lsp --root /path/to/project
```

| Option | Default | Meaning |
| --- | --- | --- |
| `--root PATH` | `.` | the Lake project root. One root per session; see "One root" below. |
| `--config PATH` | discovery | an explicit `lean-fmt.toml` |
| `--select` / `--ignore` | `[]` | rule selection, as on the command line |
| `--preview` | off | unlock preview rules |
| `--unsafe-fixes` | off | offer unsafe fixes as quickfixes |
| `--debounce-ms MS` | `150` | quiet interval before a changed buffer is re-analyzed |

Every option except `--root` can also be sent as `initializationOptions` (`configPath`, `select`, `ignore`, `preview`,
`unsafeFixes`, `debounceMs`); a client that sends neither is configured exactly as the process was started. `--root` is
fixed when the session opens: one Lake workspace per session. A client that asks to change it is told to restart, rather
than served from a setup it did not ask for.

## Two things that look like bugs and are not

**A formatted range is usually wider than the range you selected.** Formatting is command-granular: the request widens
to the layout units it touches, and the edit that comes back replaces *that* range. Selecting three lines in the middle
of a declaration reformats the declaration. Repeated range formatting is a fixed point in output coordinates, not in the
coordinates you asked in — so a client that re-sends its original range after applying an edit may see the region move
again.

**A trailing comment belongs to the declaration above it.** A comment on the line after a declaration is part of that
declaration's layout unit, not the next one's. This shows in an editor in a way it does not in a pipeline: a range
selection that stops just before a comment still formats the comment, because the comment is inside the unit the
selection expanded to.

## Incremental analysis

Each open document gets its own Lean frontend. The first analysis of a buffer runs it in full; every `didChange` after
that reuses the document's last good state instead of starting over. A repeated identical request — a code-action query
on cursor movement is the common one — is answered from the result already computed for that version. Cancelling
reaches into the frontend, so a superseded analysis stops rather than finishing in the background. Analysis reads the
buffer your editor sent, never the file on disk and never the on-disk cache.

## Multiple formatters on one file

Lean's language server offers no formatting at all — no formatting provider, no formatting method — so there is no
contention to resolve. What editors *do* need from you is a default: when more than one server is attached to a
language, most clients ask which one formats. Pick `lean-fmt`.

Both servers answer `textDocument/codeAction` and the client concatenates the menus. `lean-fmt`'s entries are titled
with the rule code they come from (`FMT003: ...`), so a menu entry is attributable. Its diagnostics carry
`source: "lean-fmt"` for the same reason.

## Configuration changes

The server does not watch `lean-fmt.toml`. File observation belongs to `lean-fmt watch`; a second watcher inside the
language server would be a second discovery path with its own staleness. Instead, `workspace/didChangeConfiguration`
re-runs discovery and re-analyzes every open document — so after editing `lean-fmt.toml`, trigger your client's
configuration-change notification (all three clients below send it when their own `lean-fmt` settings change; VS Code
and Neovim also expose a manual "restart server" command, which always works).

A `lakefile` change is different: it invalidates the exact module setup, and the honest answer is to restart the server.
It says so in a log message rather than serving answers from a workspace that no longer describes the project.

## One root

Exactly one workspace root is served per session. A client that offers several gets the first and a `window/showMessage`
naming the ones it is not serving. Two roots means two Lake workspaces and two toolchains in one process; run a second
server instead.

## VS Code

There is no published extension. With a generic LSP client extension, the inputs are:

```jsonc
{
  "command": ".lake/build/bin/lean-fmt",
  "args": ["lsp", "--root", "${workspaceFolder}"],
  "filetypes": ["lean4"],
  "rootPatterns": ["lakefile.lean", "lakefile.toml"],
  "initializationOptions": { "debounceMs": 150 }
}
```

Then make it the default formatter for Lean, or format-on-save will ask every time:

```jsonc
{
  "[lean4]": {
    "editor.defaultFormatter": "<the generic client extension's id>",
    "editor.formatOnSave": true
  }
}
```

`editor.codeActionsOnSave` with `"source.fixAll": "explicit"` runs fix-all on save; leave it off if you want fixes to
stay a deliberate act.

## Neovim (0.11+)

```lua
vim.lsp.config["lean-fmt"] = {
  cmd = { ".lake/build/bin/lean-fmt", "lsp" },
  filetypes = { "lean" },
  root_markers = { "lakefile.lean", "lakefile.toml" },
  init_options = { debounceMs = 150 },
}
vim.lsp.enable("lean-fmt")
```

`--root` can be omitted when the client starts the server in the project directory; the default is the working
directory. With `lean.nvim` also attached, pin the formatter so `vim.lsp.buf.format` does not prompt:

```lua
vim.api.nvim_create_autocmd("BufWritePre", {
  pattern = "*.lean",
  callback = function() vim.lsp.buf.format({ name = "lean-fmt" }) end,
})
```

## Emacs (lsp-mode)

`lsp-mode` attaches multiple servers to one buffer when each has a distinct `server-id`.

```elisp
(with-eval-after-load 'lsp-mode
  (lsp-register-client
   (make-lsp-client
    :new-connection (lsp-stdio-connection
                     (lambda () (list (expand-file-name ".lake/build/bin/lean-fmt") "lsp")))
    :activation-fn (lsp-activate-on "lean4")
    :server-id 'lean-fmt
    :priority 0
    :add-on? t
    :initialization-options (lambda () (list :debounceMs 150)))))
```

`:add-on? t` is the part that matters: it tells `lsp-mode` this server supplements `lean4-mode`'s rather than replacing
it. Formatting then goes to whichever attached server advertises a formatting provider — only this one.

With `eglot`, which attaches a single server per major mode, run `lean-fmt` through a formatting hook instead —
`lean-fmt format -` over the buffer — or accept that `eglot` will serve `lean-fmt` and not `lean4-mode`.

## What it does not do

No hover, completion, go-to-definition, semantic tokens, rename, or inlay hints — those belong to Lean's language
server, and this one does not duplicate them. No `$/progress` reporting. No file watching. No writes: `lean-fmt lsp`
never touches a `.lean` file or the result cache; every change reaches disk as an edit your editor applied.
