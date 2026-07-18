# The source-rule catalog

`RSR-SPEC`. This freezes which raw-source rules `lean-fmt` ships, what each means, and — the harder
half — which of the roadmap's four candidates cannot honestly be source rules at all and why. It
changes no product behavior. `RSR-IMPL` implements the accepted rules against this note.

Every acceptance claim below is measured, not assumed. The experiment is
`evidence/01-acceptance.lean`; its transcript is `evidence/01-acceptance.txt`, on
`leanprover/lean4:v4.32.0` (this repo's `lean-toolchain`).

## 1. The one fact that decides everything

A source-tier rule reads `SourceFacts.normalized` and nothing else (`LeanFmt/Rules.lean:67-74`,
`AGENTS.md`: "a module linter is handed already-normalized text and cannot observe the file's bytes
at all"). "Normalized" means `raw.crlfToLf`, and `crlfToLf` is the *only* normalization the product
performs (`LeanFmt/LosslessSource.lean:204-212`). So the question for each candidate is a byte
question: **does the phenomenon survive `crlfToLf` into a file the frontend accepts?** If it does not,
no source rule can ever see it, because a source rule only ever runs on accepted, normalized source.

Two sub-facts, both measured (`evidence/01-acceptance.txt`):

- `crlfToLf` touches only `\r\n`. It preserves a BOM, a bidi mark, a NUL, and an isolated `\r`, and
  collapses `\r\n` to `\n`. So *whatever survives into accepted source survives unchanged into
  normalized source* — the scan and the frontend see the same bytes, minus CRLF.
- A byte that is not trivia to the lexer cannot be a byte the file dropped: `Char.isWhitespace` is
  `false` for BOM (U+FEFF), RLO (U+202E), and NUL. A source rule for these is therefore a **byte
  scan**, not a trivia walk — the trivia model (`LosslessSource.Trivia`) would not represent them.

## 2. Acceptance, measured

`reject = true` means the frontend rejects the bytes: the file is **not accepted source**, so it has
no `.olean`, no facts, and no source rule ever runs on it.

| candidate bytes                     | bare, in the command stream | inside a string literal / comment |
| ----------------------------------- | --------------------------- | --------------------------------- |
| UTF-8 BOM (U+FEFF), leading or not  | **reject** (`expected token`) | accepts (U+FEFF is ordinary text) |
| isolated `\r`                       | **reject** (`isolated carriage returns are not allowed`) | n/a (`\r\n` is CRLF; lone `\r` rejected) |
| NUL / other C0 controls, DEL        | **reject** (`expected token`) | **accept** |
| bidi controls (U+202A–202E, …)      | **reject** (`expected token`) | **accept** |
| LF and CRLF intermixed (no lone `\r`) | **accept** (`crlfToLf` yields clean LF) | — |

BOM and isolated `\r` were already frozen by `ruff-01-lossless-source` `notes/01-source-authority.md`
§5 ("reject: tabs, UTF-8 BOM, isolated `\r`"); re-measured here and unchanged. The NUL/bidi
in-string/comment rows and the LF/CRLF row are new and are what this note pins.

### The acceptance boundary *is* the token context

A bare control or bidi byte in the command stream is a hard parse error, so **every such byte that
appears in accepted source is necessarily inside a string literal or a comment** — the frontend
already guaranteed it. This is the crux: it means the two accepted rules below need **no token
context** to be correct. They scan bytes; acceptance has already placed every byte they can see in a
string or comment. This is the same shape as `ruff-05`'s finding-in-range-by-construction: the
producer's discipline discharges the consumer's obligation. It is also exactly what the roadmap
demands ("reject any candidate requiring token context") — satisfied not by adding context but by
observing that acceptance supplies it.

## 3. What ships: two source-tier rules

Both are `RuleImpl.source` over `SourceFacts.normalized`, one linear byte/codepoint scan, one finding
per occurrence, **report-only** (`fix? := none`). Report-only is deliberate and conservative
(roadmap: "Security diagnostics may be report-only"; "classify fixes conservatively"): the byte lives
inside a string literal or comment — deleting it changes the program's data or a human-read comment,
which is not a change a byte-level safety argument can call safe. The formatter does not own these
bytes, so this is not "canonical formatter policy as default lint noise" (roadmap stop rule); it is a
correctness/security signal the formatter cannot express by reformatting.

### FMT003 — forbidden control byte

- **Set:** codepoints `< 0x20` **except** `0x09` (TAB) and `0x0A` (LF), plus `0x7F` (DEL). `0x0D`
  (CR) is in principle in the set but is unreachable: it cannot survive into accepted normalized
  source (lone `\r` rejected; `\r\n` collapsed). TAB is excluded — it is legitimate string content
  and its bare form is already a read-boundary rejection (`ruff-01` §5, "tabs are not allowed"),
  never a lint concern here.
- **Category:** `security`. **Default:** enabled. **Fixable:** no.
- **Severity:** `warning`.
- **Range:** the single-byte span `{ start, stop := start + 1 }` at each occurrence (these are all
  one UTF-8 byte). Offsets index the normalized source, like every other range.
- **Message:** `forbidden control byte U+00XX` (uppercase hex, four digits), e.g.
  `forbidden control byte U+0000`.

### FMT004 — suspicious bidirectional control

- **Set (Trojan Source, CVE-2021-42574):** U+202A LRE, U+202B RLE, U+202C PDF, U+202D LRO,
  U+202E RLO, U+2066 LRI, U+2067 RLI, U+2068 FSI, U+2069 PDI, U+200E LRM, U+200F RLM, U+061C ALM.
- **Category:** `security`. **Default:** enabled. **Fixable:** no.
- **Severity:** `warning`.
- **Range:** the UTF-8 byte span of the character at each occurrence (`{ start, stop := start + w }`,
  `w` its encoded width — 3 for the U+20xx marks, 2 for U+061C; measured for RLO in
  `evidence/01-acceptance.txt`). Offsets index the normalized source.
- **Message:** `suspicious bidirectional control U+XXXX` (uppercase hex), e.g.
  `suspicious bidirectional control U+202E`.

Both codes extend the existing `FMT0xx` namespace (`FMT001`, `FMT002` shipped; `FMT900` is
`ruff-07`'s suppression-directive code). No code clash.

## 4. What is rejected, and why it is not a defect to reject it

### UTF-8 BOM — not a lint finding

A BOM anywhere in the command stream is a parse error, so an accepted file has no leading BOM
(`evidence/01-acceptance.txt`: `leading BOM reject=true`). Detecting "the file starts with a BOM"
would therefore fire only on files the reader has *already rejected* — the read boundary owns this,
per `ruff-01` §5. A source rule that re-reports a read-boundary rejection is duplicated policy that
can never fire on the source it is handed. Rejected. (A BOM *inside* a string is just U+FEFF, a
zero-width no-break space; it is not "a byte-order mark" and has no distinct meaning worth a code.)

### Mixed line endings — not a lint finding, and it belongs to `ruff-01`

Two distinct things get called "mixed":

- A file with a lone `\r` is rejected outright (§2). Not accepted source; nothing to lint.
- A file intermixing `\n` and `\r\n` (no lone `\r`) **is accepted** (`evidence/01-acceptance.txt`:
  `LF/CRLF intermixed reject=false`), but `crlfToLf` erases every `\r`, so `SourceFacts.normalized`
  is uniformly LF and a source rule cannot see the original endings at all. The endings survive only
  in `LineEndings`, held by whoever read the raw bytes — never in the facts a rule reads.

So "mixed line endings" is invisible to a source rule by construction, and its only correction —
rewriting to one uniform ending — is canonical formatter output, which the roadmap forbids shipping
as default lint noise. Rejected as a rule.

There is a real observation to hand off, though: `LosslessSource.normalize` classifies an
intermixed-but-accepted file as `.crlf` (because `normalized ≠ raw`), so `denormalize .crlf` would
rewrite its bare-`\n` lines as `\r\n`. `ruff-01` §5's prose ("a mixed file is already not accepted
source") is imprecise — Lean accepts LF/CRLF intermixing. `ruff-01`'s **round-trip invariant 4**
still guards write safety (such a file fails `validFor`, so `fix` refuses it rather than corrupting
it), so this is not a live corruption and not a blocker for this stack. It is recorded here as a
`ruff-01`-owned precision gap; the fix, if wanted, is `ruff-01`'s, not a rule bolted on top.

## 5. Fixtures RSR-IMPL owes (roadmap completion contract)

Per rule: positive (control/bidi byte inside a string and inside a comment — the only places they can
occur), negative (a clean file; a file whose only "controls" are TAB/LF), Unicode (multibyte bidi
marks, ranges exact per §3), malformed-source (a rejected bare-control file stays rejected, not
silently linted), applicability (report-only: no fix emitted), suppression (`ruff-07` directives
silence FMT003/FMT004 like any code), and documentation (`docs/adding-a-rule.md` example refresh).

## 6. Decisions changed while freezing this

- The roadmap names four candidates; two survive as rules. This is not under-delivery — the roadmap
  says "add **only** source-global rules with **honest** byte-level semantics," and BOM/mixed-endings
  have no honest byte-level semantics over accepted normalized source. Rejecting them *is* the
  contract.
- No new abstraction was introduced. An earlier design considered a read-boundary "raw-source
  diagnostic" channel (findings computed from `snapshot.source` at `Application.lean:686`, where raw
  bytes, `lineEndings`, and normalized all exist) to deliver BOM/mixed-endings as 4-of-4. Rejected:
  it forks finding production away from the cached, tier-based `RuleImpl` set, and re-reports what the
  reader and formatter already own — buying a second channel to say what is already said. Two honest
  rules beat four with two of them noise.
