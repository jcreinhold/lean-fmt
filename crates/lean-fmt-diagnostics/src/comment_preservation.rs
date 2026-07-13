//! Cross-rule comment & docstring preservation golden suite.
//!
//! Every formatting rule is conservative about comments, but each rule proves that only
//! for its own fixtures. This module makes comment preservation a *first-class, shared*
//! invariant: a single [`comments`] extractor recovers the ordered multiset of every
//! comment token (line comments, block comments, docstrings `/-- -/`, module docs
//! `/-! -/`, including nested block comments), and each golden fixture below drives a real
//! rule over source with a comment in a specific syntactic position, applies the emitted
//! fixes through the patch engine, and asserts the comment sequence is **identical**
//! before and after — and that a re-run is a fixed point.
//!
//! The corpus covers a comment in every position a rule touches so far: attached to an
//! import, between two commands (blank-line collapse), near an `end`, between declaration
//! header tokens, after `by` in a tactic block, and a docstring / module-doc / trailing
//! line comment under the text rules — plus a nested block comment.
//!
//! The module is compiled only under `#[cfg(test)]` (see `lib.rs`); it drives the
//! crate-internal rule functions directly.
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::panic,
    clippy::arithmetic_side_effects,
    clippy::literal_string_with_formatting_args
)]

use lean_fmt_edit::{
    DeclHeaderRecord, Diagnostic, EditSet, ImportRecord, LineColumn, LineColumnRange, SyntaxRegion, TacticBlockRecord,
    TacticBulletMarker, TextRange,
};

use crate::engine::{RuleContext, check};
use crate::selection::RuleSelection;
use crate::{declaration, imports, layout, tactic};

/// The ordered multiset of comment tokens in `src`: each line comment (`-- …` to end of
/// line), block comment (`/- … -/`, nesting-aware), docstring (`/-- … -/`), and module
/// doc (`/-! … -/`), captured verbatim in source order. Delimiter markers are ASCII, so
/// every slice endpoint lands on a char boundary. (Fixtures avoid comment markers inside
/// string/char literals, which this text scan does not model.)
fn comments(src: &str) -> Vec<String> {
    let b = src.as_bytes();
    let mut out = Vec::new();
    let mut i = 0usize;
    while i < b.len() {
        if b[i..].starts_with(b"/-") {
            // A block comment — covers `/--` docstrings and `/-!` module docs too, since
            // both open with `/-`. Nesting-aware: `/- outer /- inner -/ -/` is one token.
            let start = i;
            i += 2;
            let mut depth = 1usize;
            while i < b.len() && depth > 0 {
                if b[i..].starts_with(b"/-") {
                    depth += 1;
                    i += 2;
                } else if b[i..].starts_with(b"-/") {
                    depth -= 1;
                    i += 2;
                } else {
                    i += 1;
                }
            }
            out.push(src[start..i].to_owned());
        } else if b[i..].starts_with(b"--") {
            let start = i;
            while i < b.len() && b[i] != b'\n' {
                i += 1;
            }
            out.push(src[start..i].to_owned());
        } else {
            i += 1;
        }
    }
    out
}

/// Maximal runs of ASCII whitespace in `source` — a faithful trivia model for the
/// comment-free *token* gaps in these fixtures (inter-token whitespace is the trivia).
fn whitespace_trivia(source: &str) -> Vec<TextRange> {
    let bytes = source.as_bytes();
    let mut runs = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i].is_ascii_whitespace() {
            let start = i;
            while i < bytes.len() && bytes[i].is_ascii_whitespace() {
                i += 1;
            }
            runs.push(TextRange::new(start, i));
        } else {
            i += 1;
        }
    }
    runs
}

/// Apply every fix in `diagnostics` to `source` through the patch engine.
fn apply_all(source: &str, diagnostics: &[Diagnostic]) -> String {
    let mut edits = Vec::new();
    for diagnostic in diagnostics {
        if let Some(EditSet { edits: e }) = &diagnostic.fix {
            edits.extend(e.iter().cloned());
        }
    }
    EditSet { edits }.apply(source).unwrap().output
}

/// The 1-based line / 0-based codepoint column of byte offset `pos` in `src`.
fn lc(src: &str, pos: usize) -> LineColumn {
    let mut line = 1u32;
    let mut col = 0u32;
    for (i, ch) in src.char_indices() {
        if i >= pos {
            break;
        }
        if ch == '\n' {
            line += 1;
            col = 0;
        } else {
            col += 1;
        }
    }
    LineColumn::new(line, col)
}

/// A `SyntaxRegion` for `src[start..end]` with faithfully computed display coordinates.
fn region(kind: &str, src: &str, start: usize, end: usize) -> SyntaxRegion {
    SyntaxRegion {
        kind: kind.to_owned(),
        range: TextRange::new(start, end),
        line_column: LineColumnRange {
            start: lc(src, start),
            end: lc(src, end),
        },
    }
}

fn tr(start: usize, end: usize) -> TextRange {
    TextRange::new(start, end)
}

/// Locate each `import <module>` statement's byte range (mirrors the Lean parser: one
/// record per statement, module name last token, trailing `--` excluded from the range).
fn imports_of(source: &str) -> Vec<ImportRecord> {
    let mut records = Vec::new();
    let mut offset = 0usize;
    for line in source.split_inclusive('\n') {
        let trimmed = line.trim_end();
        if let Some(rest) = trimmed.strip_prefix("import ") {
            let module = rest.split_whitespace().last().unwrap_or("").to_owned();
            let stmt = trimmed.split("--").next().unwrap_or(trimmed).trim_end();
            records.push(ImportRecord {
                module,
                range: TextRange::new(offset, offset + stmt.len()),
            });
        }
        offset += line.len();
    }
    records
}

/// Assert a rule preserves comments and is idempotent: `comments` is identical before and
/// after applying `once = f(before)`, and `f(once) == once`.
fn assert_preserves(before: &str, once: &str, refix: impl Fn(&str) -> String) {
    assert_eq!(
        comments(before),
        comments(once),
        "comment multiset/order must be identical after formatting"
    );
    assert_eq!(refix(once), once, "formatting must be a fixed point");
}

#[test]
fn extractor_recovers_every_comment_kind_in_order() {
    let src = "-- line\n/- block -/\n/-- doc -/\n/-! mod -/\n/- a /- nested -/ b -/\n";
    assert_eq!(
        comments(src),
        vec![
            "-- line".to_owned(),
            "/- block -/".to_owned(),
            "/-- doc -/".to_owned(),
            "/-! mod -/".to_owned(),
            "/- a /- nested -/ b -/".to_owned(),
        ]
    );
}

#[test]
fn imports_sorted_keeps_attached_comment() {
    // The comment documents A and must travel with it when B sorts below.
    let before = "import B\n-- doc for A\nimport A\n";
    let run = |s: &str| {
        let recs = imports_of(s);
        let ctx = RuleContext::new(s, "A.lean", &[]).with_imports(&recs);
        imports::sorted(&ctx)
    };
    let once = apply_all(before, &run(before));
    assert_eq!(once, "-- doc for A\nimport A\nimport B\n");
    assert_preserves(before, &once, |s| apply_all(s, &run(s)));
}

#[test]
fn blank_lines_preserve_comment_between_commands() {
    // `def a := 1` <blanks> `-- mid` <blanks> `def b := 2`. The rule collapses each blank
    // run but must never absorb the comment line.
    let before = "def a := 1\n\n\n-- mid\n\n\ndef b := 2\n";
    assert_eq!(&before[0..10], "def a := 1");
    assert_eq!(&before[13..19], "-- mid");
    assert_eq!(&before[22..32], "def b := 2");
    let run = |s: &str| {
        // Recompute the two command regions against the (shrinking) source by locating
        // the two `def` lines, so the fixed-point re-run is honest.
        let a = s.find("def a := 1").unwrap();
        let b = s.find("def b := 2").unwrap();
        let regions = [
            region("Lean.Parser.Command.declaration", s, a, a + 10),
            region("Lean.Parser.Command.declaration", s, b, b + 10),
        ];
        let runs = whitespace_trivia(s);
        let ctx = RuleContext::new(s, "A.lean", &runs).with_regions(&regions);
        layout::blank_lines(&ctx)
    };
    let once = apply_all(before, &run(before));
    assert_eq!(once, "def a := 1\n\n-- mid\n\ndef b := 2\n");
    assert_preserves(before, &once, |s| apply_all(s, &run(s)));
}

#[test]
fn blank_lines_preserve_nested_block_comment() {
    let before = "def a := 1\n\n\n/- outer /- inner -/ still -/\n\n\ndef b := 2\n";
    assert_eq!(comments(before), vec!["/- outer /- inner -/ still -/".to_owned()]);
    let run = |s: &str| {
        let a = s.find("def a := 1").unwrap();
        let b = s.find("def b := 2").unwrap();
        let regions = [
            region("Lean.Parser.Command.declaration", s, a, a + 10),
            region("Lean.Parser.Command.declaration", s, b, b + 10),
        ];
        let runs = whitespace_trivia(s);
        let ctx = RuleContext::new(s, "A.lean", &runs).with_regions(&regions);
        layout::blank_lines(&ctx)
    };
    let once = apply_all(before, &run(before));
    assert_preserves(before, &once, |s| apply_all(s, &run(s)));
}

#[test]
fn end_name_preserves_nearby_comment() {
    // `namespace Foo … end` gains `end Foo`; a comment inside the namespace is untouched.
    let before = "namespace Foo\n-- inside\ndef a := 1\nend\n";
    assert_eq!(&before[0..13], "namespace Foo");
    assert_eq!(&before[14..23], "-- inside");
    assert_eq!(&before[35..38], "end");
    let run = |s: &str| {
        let ns = s.find("namespace Foo").unwrap();
        let da = s.find("def a := 1").unwrap();
        // The `end` command spans through any existing end-name to the line end, so the
        // fixed-point re-run sees `end Foo` as already-named (not a bare `end`).
        let en = s.find("end").unwrap();
        let en_end = s[en..].find('\n').map_or(s.len(), |o| en + o);
        let regions = [
            region("Lean.Parser.Command.namespace", s, ns, ns + 13),
            region("Lean.Parser.Command.declaration", s, da, da + 10),
            region("Lean.Parser.Command.end", s, en, en_end),
        ];
        let runs = whitespace_trivia(s);
        let ctx = RuleContext::new(s, "A.lean", &runs).with_regions(&regions);
        layout::end_name(&ctx)
    };
    let once = apply_all(before, &run(before));
    assert_eq!(once, "namespace Foo\n-- inside\ndef a := 1\nend Foo\n");
    assert_preserves(before, &once, |s| apply_all(s, &run(s)));
}

#[test]
fn header_spacing_preserves_comment_between_tokens() {
    // A block comment between the name and `:=`; the rule must not rewrite the whitespace
    // touching it. Other gaps (a crammed keyword→name) still normalize.
    let before = "def  f /- note -/ := x\n";
    assert_eq!(&before[7..17], "/- note -/");
    let decls = [DeclHeaderRecord {
        kind: "Lean.Parser.Command.definition".to_owned(),
        range: tr(0, 22),
        keyword: Some(tr(0, 3)),
        name: Some(tr(5, 6)),
        binders: Vec::new(),
        sig_colon: None,
        assign: Some(tr(18, 20)),
        where_kw: None,
    }];
    let run = |s: &str, d: &[DeclHeaderRecord]| {
        let runs = whitespace_trivia(s);
        let ctx = RuleContext::new(s, "A.lean", &runs).with_decls(d);
        declaration::header_spacing(&ctx)
    };
    let once = apply_all(before, &run(before, &decls));
    // The `def  f` double space collapses; the comment and its flanking spaces are kept.
    assert_eq!(once, "def f /- note -/ := x\n");
    let once_decls = [DeclHeaderRecord {
        kind: "Lean.Parser.Command.definition".to_owned(),
        range: tr(0, 21),
        keyword: Some(tr(0, 3)),
        name: Some(tr(4, 5)),
        binders: Vec::new(),
        sig_colon: None,
        assign: Some(tr(17, 19)),
        where_kw: None,
    }];
    assert_preserves(before, &once, |s| apply_all(s, &run(s, &once_decls)));
}

#[test]
fn tactic_spacing_preserves_comment_after_by() {
    // A comment immediately follows `by`; the tactic runs on the next line. The rule must
    // not rewrite the whitespace touching the comment.
    let before = "theorem t : True := by -- go\n  trivial\n";
    assert_eq!(&before[20..22], "by");
    let tactics = [TacticBlockRecord {
        by_kw: tr(20, 22),
        seq: Some(tr(31, 38)),
        base_column: Some(2),
        first_step: Some(tr(31, 38)),
        bullets: Vec::new(),
    }];
    let run = |s: &str, t: &[TacticBlockRecord]| {
        let runs = whitespace_trivia(s);
        let ctx = RuleContext::new(s, "A.lean", &runs).with_tactics(t);
        tactic::block_spacing(&ctx)
    };
    let once = apply_all(before, &run(before, &tactics));
    assert_eq!(once, before, "comment after by leaves the block untouched");
    assert_preserves(before, &once, |s| apply_all(s, &run(s, &tactics)));
}

#[test]
fn tactic_spacing_preserves_same_line_comment_after_marker() {
    // A `·` marker whose tactic and a trailing comment share the line: `·  foo -- c`.
    // The gap after `·` collapses to one space; the comment is untouched.
    let before = "theorem t : True := by\n  ·  trivial -- c\n";
    // `·` is 2 bytes.
    let dot = before.find('·').unwrap();
    assert_eq!(&before[dot..dot + 2], "·");
    let run = |s: &str| {
        let d = s.find('·').unwrap();
        let tacs = [TacticBlockRecord {
            by_kw: tr(20, 22),
            seq: Some(tr(d, s.trim_end().len())),
            base_column: Some(2),
            first_step: Some(tr(d, d + 2)),
            bullets: vec![TacticBulletMarker {
                kind: "cdot".to_owned(),
                range: tr(d, d + 2),
            }],
        }];
        let runs = whitespace_trivia(s);
        let ctx = RuleContext::new(s, "A.lean", &runs).with_tactics(&tacs);
        tactic::block_spacing(&ctx)
    };
    let once = apply_all(before, &run(before));
    assert_eq!(once, "theorem t : True := by\n  · trivial -- c\n");
    assert_preserves(before, &once, |s| apply_all(s, &run(s)));
}

#[test]
fn text_rules_preserve_docstrings_and_line_comment() {
    // Module doc, docstring, a code line with trailing whitespace, and a trailing line
    // comment with no final newline. The text rules trim the trailing spaces and add the
    // final newline; every comment token survives verbatim.
    let before = "/-! module -/\n/-- doc -/\ndef a := 1  \n-- tail comment";
    assert_eq!(
        comments(before),
        vec![
            "/-! module -/".to_owned(),
            "/-- doc -/".to_owned(),
            "-- tail comment".to_owned(),
        ]
    );
    let run = |s: &str| {
        let runs = whitespace_trivia(s);
        let ctx = RuleContext::new(s, "A.lean", &runs);
        check(&ctx, &RuleSelection::default())
    };
    let once = apply_all(before, &run(before));
    assert_eq!(once, "/-! module -/\n/-- doc -/\ndef a := 1\n-- tail comment\n");
    assert_preserves(before, &once, |s| apply_all(s, &run(s)));
}
