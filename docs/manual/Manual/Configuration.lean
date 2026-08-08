import VersoManual

open Verso.Genre Manual
open Verso.Genre.Manual.InlineLean

#doc (Manual) "Configuration" =>
%%%
tag := "configuration"
%%%

Configuration is optional. With no config file at all, every `.lean` file in the project outside
`.lake` is checked with the default settings.

# Where the settings come from

Walking up from each source file toward the project root, the *closest* `lean-fmt.toml` — or
`.lean-fmt.toml` — governs that file.

Configs do not merge. A config in a subdirectory replaces its ancestors for that subtree rather
than layering on top of them. This is worth knowing before you add the second one: a nested config
that sets a single key silently drops every other setting its parent made, so a nested config
should be a complete statement of what that subtree wants.

Having both spellings of the name in one directory is an error rather than a precedence puzzle.
`--config PATH` skips discovery entirely and anchors at the project root.

# A worked file

```
extend = "../shared/lean-fmt.toml"
include = ["LeanLib/**/*.lean", "Main.lean"]
exclude = ["Generated/**"]
respect-gitignore = true

[format]
line-width = 100
declaration-body = "next-line"
reflow-comments = false

[lint]
select = ["all"]
ignore = ["FMT004"]
per-file-ignores = { "Legacy/*.lean" = ["FMT005"] }
```

`[format]` holds the settings that change the bytes on disk. `[lint]` holds rule selection. The
split is the same one the commands make: formatting and findings are separate questions, and a key
belongs to whichever one it can actually affect.

# The keys worth knowing first

`line-width` is the only number that changes layout, and it accepts 1 to 1000. Everything in
{ref "layout"}[the layout chapter] follows from it.

`declaration-body` chooses where a body goes relative to `:=`. The default, `"next-line"`, puts it
on its own line. `"same-line"` keeps it on the `:=` line whenever the joined line fits, and breaks
exactly like the default when it does not.

`reflow-comments` is off by default. Turned on, a standalone `--` comment block whose rows overflow
the margin is repacked to fit: the words keep their order, the lines do not. It leaves alone
anything where rewrapping would do more harm than good — trailing comments, doc comments, block
comments, list items, and blocks that already fit. A block with under twenty columns of room is
also left alone, on the grounds that confetti is worse than an overflow.

`pinned-comments` lists phrases that mark a comment as immovable. An inline comment containing one
is never moved and never has its line split, even when the code alone overflows. The default is
`["shake: keep"]`, because a tooling directive that drifts off the import it annotates has stopped
meaning anything. Setting the key replaces the default rather than adding to it; an empty list
turns pinning off.

`exclude` keeps paths out. `force-exclude` extends it to files named explicitly on the command
line, which is what you want when an editor or a pre-commit hook passes paths in directly.

# Comments do not change layout

This one is not configurable, and it surprises people often enough to be worth stating plainly.

Break decisions are computed from the code alone. A trailing comment never changes the layout of
the code it trails. If the code fits the width, the line stays whole and the comment overflows the
margin; if the code alone overflows, it breaks and the comment follows whatever it annotates.

The alternative is worse. Letting a comment's width push the code around would split
`public import X` across lines to make room for a note — and the note would usually overflow
anyway.

# Checking what applies

`lean-fmt config` prints the effective configuration for a file: which config file governs it and
what every setting resolved to. When a file is being formatted in a way you did not expect, that
is the first thing to run, because it answers whether the surprise is in the configuration or in
the layout.

The full key reference, including the `extend` chain's merge behaviour and the import-layout
settings the organizer uses, is in
[the configuration reference](https://github.com/jcreinhold/lean-fmt/blob/main/docs/configuration.md).
